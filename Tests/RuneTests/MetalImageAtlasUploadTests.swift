#if canImport(Metal) && canImport(QuartzCore)
import Metal
import RuneMotion
import RuneRef
import Testing
@testable import Rune

@Suite("Metal image atlas updates")
struct MetalImageAtlasUploadTests {
    private let red = SIMD4<UInt8>(255, 0, 0, 255)
    private let green = SIMD4<UInt8>(0, 255, 0, 255)
    private let blue = SIMD4<UInt8>(0, 0, 255, 255)
    private let white = SIMD4<UInt8>(255, 255, 255, 255)

    private func fill(_ pixels: Pixels, with color: SIMD4<UInt8>) {
        let texel = [color.x, color.y, color.z, color.w]
        pixels.set(width: 2, height: 2, rgba: texel + texel + texel + texel)
    }

    private func strip(_ left: Pixels, _ right: Pixels) -> Runtime<Void> {
        let whitePixel = RGBA8Atlas(width: 1, height: 1, texels: [255, 255, 255, 255])
        return Runtime(state: (), viewport: Vec2(12, 4), pixelScale: 1) { _, _ in
            el().size(12, 4)
                .child(el().absolute(x: 0, y: 0).size(4, 4).pixels(left))
                .child(image(whitePixel).absolute(x: 4, y: 0).size(4, 4))
                .child(el().absolute(x: 8, y: 0).size(4, 4).pixels(right))
        }
    }

    private func colors(_ result: Frame) -> [SIMD4<UInt8>] {
        [2, 6, 10].map { result.pixel(x: $0, y: 2) }
    }

    // Exclusive texel edges; an image's instance UV is encoded as origin plus size.
    private func edges(in frame: RenderFrame, at screenX: Float) throws -> SIMD4<Int> {
        let image = try #require(frame.instances.first { $0.params.y == KIND_IMAGE && $0.rect.x == screenX })
        let uv = image.uv
        return SIMD4(Int(uv.x), Int(uv.y), Int(uv.x + uv.z), Int(uv.y + uv.w))
    }

    private func uploadedEdges(_ renderer: MetalRenderer) throws -> SIMD4<Int> {
        let region = try #require(renderer.uploader.lastImageUploadRegion)
        return SIMD4(region.origin.x, region.origin.y,
                     region.origin.x + region.size.width, region.origin.y + region.size.height)
    }

    private func malformedSizes(limit: Int, channels: Int) -> [(width: Int, height: Int, bytes: Int)] {
        [(0, 2, 0), (2, -1, 0), (Int.max, 2, 1),
         (limit + 1, 1, (limit + 1) * channels), (1, limit + 1, (limit + 1) * channels),
         (2, 2, 4 * channels - 1), (2, 2, 4 * channels + 1)]
    }

    private func textureBytes(_ texture: MTLTexture, channels: Int) -> [UInt8] {
        let stride = texture.width * channels
        var result = [UInt8](repeating: 0, count: stride * texture.height)
        texture.getBytes(&result, bytesPerRow: stride,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return result
    }

    @Test func malformedManualAtlasesPreserveTheLastValidUpload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let uploader = AtlasUploader()
        let limit = MetalTextureLimits.max2D(on: device)
        let validGlyph = R8Atlas(width: 2, height: 1, texels: [90, 220])
        let glyph = try #require(uploader.syncGlyphAtlas(device: device, atlas: validGlyph, generation: 0))
        #expect(textureBytes(glyph, channels: 1) == validGlyph.texels)
        for size in malformedSizes(limit: limit, channels: 1) {
            var invalid = R8Atlas(texels: [UInt8](repeating: 91, count: size.bytes))
            invalid.width = size.width
            invalid.height = size.height
            #expect(uploader.syncGlyphAtlas(device: device, atlas: invalid, generation: 1) == nil,
                    "R8 input \(size)")
            #expect(uploader.glyphTexture === glyph)
            #expect(uploader.glyphGeneration == 0)
            #expect(uploader.glyphSize == SIMD2(2, 1))
        }
        #expect(textureBytes(glyph, channels: 1) == validGlyph.texels)

        let validImage = RGBA8Atlas(texels: [51, 120, 4, 180])
        let image = try #require(uploader.syncImageAtlas(device: device, atlas: validImage, revision: 0))
        #expect(textureBytes(image, channels: 4) == validImage.texels)
        for size in malformedSizes(limit: limit, channels: 4) {
            var invalid = RGBA8Atlas(texels: [UInt8](repeating: 51, count: size.bytes))
            invalid.width = size.width
            invalid.height = size.height
            #expect(uploader.syncImageAtlas(device: device, atlas: invalid, revision: 1) == nil,
                    "RGBA input \(size)")
            #expect(uploader.imageTexture === image)
            #expect(uploader.imageRevision == 0)
            #expect(uploader.imageSize == SIMD2(1, 1))
        }
        #expect(textureBytes(image, channels: 4) == validImage.texels)
    }

    @Test func invalidSecondPageLeavesTheOriginalPageSetAndRevisionIntact() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let uploader = AtlasUploader()
        let red = RGBA8Atlas(texels: [255, 0, 0, 255])
        let blue = RGBA8Atlas(texels: [0, 0, 255, 255])
        let green = RGBA8Atlas(texels: [0, 255, 0, 255])
        let pages = uploader.syncImagePages(device: device, pages: [red, blue], fallback: .init(), revision: 0)
        try #require(pages.count == 2)
        #expect(textureBytes(pages[0], channels: 4) == red.texels)
        #expect(textureBytes(pages[1], channels: 4) == blue.texels)
        let limit = MetalTextureLimits.max2D(on: device)
        for size in malformedSizes(limit: limit, channels: 4) {
            var invalid = RGBA8Atlas(texels: [UInt8](repeating: 0, count: size.bytes))
            invalid.width = size.width
            invalid.height = size.height
            let rejected = uploader.syncImagePages(device: device, pages: [green, invalid], fallback: .init(), revision: 1)
            #expect(rejected.isEmpty, "second page \(size)")
            #expect(uploader.imageRevision == 0)
            #expect(uploader.imageTexture === pages[0])
            try #require(uploader.imageTextures.count == 2)
            #expect(uploader.imageTextures[0] === pages[0])
            #expect(uploader.imageTextures[1] === pages[1])
        }
        #expect(textureBytes(pages[0], channels: 4) == red.texels)
        #expect(textureBytes(pages[1], channels: 4) == blue.texels)

        let malformedFallback = RGBA8Atlas(width: 2, height: 2, texels: [0, 0, 0, 0])
        #expect(uploader.syncImagePages(device: device, pages: [], fallback: malformedFallback, revision: 1).isEmpty)
        #expect(uploader.imageRevision == 0)
        try #require(uploader.imageTextures.count == 2)
        #expect(uploader.imageTextures[0] === pages[0])
        #expect(uploader.imageTextures[1] === pages[1])

        let updated = uploader.syncImagePages(device: device, pages: [green, red], fallback: .init(), revision: 1)
        try #require(updated.count == 2)
        #expect(textureBytes(updated[0], channels: 4) == green.texels)
        #expect(textureBytes(updated[1], channels: 4) == red.texels)
        #expect(uploader.imageRevision == 1)
    }

    @Test func transparentFallbackAtlasesUploadAtRevisionZero() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let uploader = AtlasUploader()
        let glyph = try #require(uploader.syncGlyphAtlas(device: device, atlas: R8Atlas(texels: []), generation: 0))
        #expect(textureBytes(glyph, channels: 1) == [0])
        let fallback = uploader.syncImagePages(device: device, pages: [], fallback: RGBA8Atlas(), revision: 0)
        try #require(fallback.count == 1)
        #expect(textureBytes(fallback[0], channels: 4) == [0, 0, 0, 0])
    }

    @Test func oversizedCachedLayerAllocatesOnlyItsVisibleRegion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = LayersPool()
        let viewport = SIMD2<Float>(36, 19)
        let bounds = SIMD4<Float>(0, 0, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var begin = RenderInstance.beginLayer(bounds: bounds, clip: NO_CLIP, spec: .init(opacity: 0.5))
        begin.params.w = 1
        begin.radii = packU64ToFloat4(7)
        begin.uv = packU64ToFloat4(11)
        let content = RenderInstance(rect: SIMD4(0, 0, viewport.x, viewport.y), fill: .one)
        pool.prepareLayers(device: device, instances: [begin, content, .endLayer()], viewport: viewport)
        #expect(pool.planner.dispositions == [.render(rect: SIMD4(0, 0, viewport.x, viewport.y), cache: nil)])
        let target = try #require(pool.targetEntry(at: 0))
        #expect(target.contentSize == viewport)
        #expect(target.slot.texture.width <= LayerPoolLimits.maxDimension)
        #expect(target.slot.texture.height <= LayerPoolLimits.maxDimension)
        #expect(pool.stats().cachedLayers == 0)
    }

    @Test func streamedRectanglesShareAnUploadAndLeaveNeighborsIntact() throws {
        let left = Pixels(), right = Pixels()
        fill(left, with: red)
        fill(right, with: blue)
        let runtime = strip(left, right)
        let renderer = try MetalRenderer()
        let initial = runtime.renderFrame(at: 0)
        #expect(try colors(renderer.renderOffscreen(initial)) == [red, white, blue])
        #expect(try uploadedEdges(renderer) == SIMD4(0, 0, initial.images.width, initial.images.height))
        let texture = try #require(renderer.uploader.imageTexture)

        fill(left, with: green)
        let single = runtime.renderFrame(at: 1)
        let leftEdges = try edges(in: single, at: 0)
        #expect(leftEdges.z - leftEdges.x == 2 && leftEdges.w - leftEdges.y == 2)
        renderer.prepare(frame: single, viewport: (12, 4))
        #expect(try uploadedEdges(renderer) == leftEdges)
        #expect(try colors(renderer.renderOffscreen(single)) == [green, white, blue])
        #expect(renderer.uploader.imageTexture === texture)

        fill(left, with: blue)
        fill(right, with: red)
        let both = runtime.renderFrame(at: 2)
        let rightEdges = try edges(in: both, at: 8)
        let union = SIMD4(min(leftEdges.x, rightEdges.x), min(leftEdges.y, rightEdges.y),
                          max(leftEdges.z, rightEdges.z), max(leftEdges.w, rightEdges.w))
        #expect(try colors(renderer.renderOffscreen(both)) == [blue, white, red])
        #expect(try uploadedEdges(renderer) == union)

        let previousBytes = renderer.uploader.imageUploadBytes
        let repeatFrame = runtime.renderFrame(at: 3)
        #expect(repeatFrame.imageRevision == both.imageRevision)
        #expect(try colors(renderer.renderOffscreen(repeatFrame)) == [blue, white, red])
        #expect(renderer.uploader.imageUploadBytes == previousBytes)
        #expect(renderer.uploader.imageTexture === texture)

        let wide = initial.images.width + 2
        left.set(width: UInt32(wide), height: 2, rgba: [UInt8](repeating: 255, count: wide * 2 * 4))
        let grown = runtime.renderFrame(at: 4)
        let sprite = try #require(grown.instances.first { $0.params.y == KIND_IMAGE && $0.rect.x == 0 })
        let index = Int(sprite.params.x)
        let page = grown.imagePages.isEmpty ? grown.images : grown.imagePages[index]
        #expect(page.width >= wide)
        #expect(try colors(renderer.renderOffscreen(grown)) == [white, white, red])
        #expect(try uploadedEdges(renderer) == SIMD4(0, 0, page.width, page.height))
        #expect(renderer.uploader.imageTextures[index] !== texture)
    }

    @Test func skippedOlderAndForeignSnapshotsRestoreTheWholeTexture() throws {
        let left = Pixels(), right = Pixels()
        fill(left, with: red)
        fill(right, with: blue)
        let runtime = strip(left, right)
        let renderer = try MetalRenderer()
        let first = runtime.renderFrame(at: 0)
        let all = SIMD4(0, 0, first.images.width, first.images.height)
        _ = try renderer.renderOffscreen(first)

        fill(left, with: green)
        let skipped = runtime.renderFrame(at: 1)
        fill(right, with: red)
        let next = runtime.renderFrame(at: 2)
        #expect(try colors(renderer.renderOffscreen(next)) == [green, white, red])
        #expect(try uploadedEdges(renderer) == all)
        #expect(try colors(renderer.renderOffscreen(skipped)) == [green, white, blue])
        #expect(try uploadedEdges(renderer) == all)

        let otherLeft = Pixels(), otherRight = Pixels()
        fill(otherLeft, with: blue)
        fill(otherRight, with: green)
        let foreign = strip(otherLeft, otherRight).renderFrame(at: 0)
        #expect(foreign.images.width == first.images.width && foreign.images.height == first.images.height)
        #expect(try colors(renderer.renderOffscreen(foreign)) == [blue, white, green])
        #expect(try uploadedEdges(renderer) == all)
        #expect(try colors(renderer.renderOffscreen(first)) == [red, white, blue])
        #expect(try uploadedEdges(renderer) == all)
    }

    @Test func replacingAPublicAtlasInvalidatesItsRuntimePatch() throws {
        let left = Pixels(), right = Pixels()
        fill(left, with: red)
        fill(right, with: green)
        let runtime = strip(left, right)
        let renderer = try MetalRenderer()
        let first = runtime.renderFrame(at: 0)
        _ = try renderer.renderOffscreen(first)

        fill(right, with: blue)
        var replacement = runtime.renderFrame(at: 1)
        // The pristine snapshot already has a newer revision than the last uploaded
        // frame. Replacing texels outside its pending patch must invalidate that hint.
        let fixed = try edges(in: replacement, at: 4)
        let offset = 4 * (fixed.y * replacement.images.width + fixed.x)
        replacement.images.texels.replaceSubrange(offset..<(offset + 4), with: [0, 255, 0, 255])
        #expect(try colors(renderer.renderOffscreen(replacement)) == [red, green, blue])
        let all = SIMD4(0, 0, replacement.images.width, replacement.images.height)
        #expect(try uploadedEdges(renderer) == all)

        fill(left, with: blue)
        let pristine = runtime.renderFrame(at: 2)
        #expect(try colors(renderer.renderOffscreen(pristine)) == [blue, white, blue])
        #expect(try uploadedEdges(renderer) == all)
    }

    @Test func revisedPagesUploadOnlyTheirOwnChangesAndKeepEncodedReaders() throws {
        let renderer = try MetalRenderer()
        let device = renderer.device
        func page(_ color: SIMD4<UInt8>) -> RGBA8Atlas {
            RGBA8Atlas(width: 3, height: 2, texels: (0..<6).flatMap { _ in [color.x, color.y, color.z, color.w] })
        }
        func instance(_ index: Int, left: Int) -> RenderInstance {
            RenderInstance(rect: SIMD4(Float(left), 0, 4, 4), fill: .one,
                           params: SIMD4(Float(index), KIND_IMAGE, 0, 0),
                           uv: SIMD4(1, 0, 1, 1), clip: NO_CLIP)
        }
        let redPage = page(red)
        let bluePage = page(blue)
        var first = RenderFrame(width: 12, height: 4, imagePages: [redPage, bluePage], imageRevision: 2,
                                instances: [instance(1, left: 0), instance(0, left: 4), instance(1, left: 8)])
        first.imagePageRevisions = [1, 2]
        first.imagePagePatches = [nil, nil]
        #expect(try colors(renderer.renderOffscreen(first)) == [blue, red, blue])
        let initial = renderer.uploader.imageTextures
        let initialBytes = renderer.uploader.imageUploadBytes
        #expect(initialBytes == 48)

        var live = first
        live.imageRevision = 3
        live.imagePages[1].texels.replaceSubrange(4..<8, with: [0, 255, 0, 255])
        live.imagePageRevisions = [1, 3]
        live.imagePagePatches = [nil, .init(fromRevision: 2, edges: SIMD4(1, 0, 2, 1))]
        #expect(try colors(renderer.renderOffscreen(live)) == [green, red, green])
        #expect(renderer.uploader.imageUploadBytes == initialBytes + 4)
        #expect(renderer.uploader.imageTextures[0] === initial[0])
        #expect(renderer.uploader.imageTextures[1] === initial[1])
        _ = try renderer.renderOffscreen(live)
        #expect(renderer.uploader.imageUploadBytes == initialBytes + 4)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 12, height: 4, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let reader = try #require(renderer.commandQueue.makeCommandBuffer())
        _ = renderer.drawRange(frame: live, into: target, commandBuffer: reader)
        var next = live
        next.imageRevision = 4
        next.imagePages[1] = page(white)
        next.imagePageRevisions = [1, 4]
        next.imagePagePatches = [nil, .init(fromRevision: 3, edges: SIMD4(0, 0, 3, 2))]
        try renderer.prepare(frame: next, viewport: (12, 4)).get()
        #expect(renderer.uploader.imageTextures[0] === initial[0])
        #expect(renderer.uploader.imageTextures[1] !== initial[1])
        reader.commit()
        reader.waitUntilCompleted()
        if let error = reader.error { throw error }
        var held = [UInt8](repeating: 0, count: 4)
        target.getBytes(&held, bytesPerRow: 4, from: MTLRegionMake2D(2, 2, 1, 1), mipmapLevel: 0)
        #expect(held == [0, 255, 0, 255])
        #expect(try colors(renderer.renderOffscreen(next)) == [white, red, white])

        let beforeRestore = renderer.uploader.imageUploadBytes
        #expect(try colors(renderer.renderOffscreen(first)) == [blue, red, blue])
        #expect(renderer.uploader.imageUploadBytes == beforeRestore + 24)
        var manual = first
        manual.imagePages[0] = page(white)
        #expect(try colors(renderer.renderOffscreen(manual)) == [blue, white, blue])
        manual.imagePages[0] = page(green)
        #expect(try colors(renderer.renderOffscreen(manual)) == [blue, green, blue])
        manual.imagePages[1].texels = []
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        #expect(try colors(renderer.renderOffscreen(manual)) == [black, green, black])
        manual.imagePages.removeLast()
        #expect(try colors(renderer.renderOffscreen(manual)) == [black, green, black])
    }

    @Test func newImagePageRebindsAnUnchangedInstanceList() {
        let uploader = AtlasUploader()
        let image = RenderInstance(rect: SIMD4(0, 0, 4, 4), fill: .one, params: SIMD4(1, KIND_IMAGE, 0, 0))
        uploader.prepareBatches(instances: [image], imagePageCount: 1)
        #expect(uploader.imageBatches.first?.1 == .image(1) && uploader.usesMissingImagePage)
        uploader.prepareBatches(instances: [image], imagePageCount: 2)
        #expect(uploader.imageBatches.first?.1 == .image(1) && !uploader.usesMissingImagePage)
    }

    @Test func preparingTheNextFramePreservesAnUncommittedDraw() throws {
        let left = Pixels(), right = Pixels()
        fill(left, with: red)
        fill(right, with: white)
        let runtime = strip(left, right)
        let renderer = try MetalRenderer()
        let first = runtime.renderFrame(at: 0)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: first.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb,
            width: first.width, height: first.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let commands = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.drawRange(frame: first, into: target, commandBuffer: commands)
        let priorTexture = try #require(renderer.uploader.imageTexture)

        fill(left, with: blue)
        let next = runtime.renderFrame(at: 1)
        renderer.prepare(frame: next, viewport: (12, 4))
        #expect(renderer.uploader.imageTexture !== priorTexture)
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        var bgra = [UInt8](repeating: 0, count: 4)
        target.getBytes(&bgra, bytesPerRow: 4, from: MTLRegionMake2D(2, 2, 1, 1), mipmapLevel: 0)
        #expect(bgra == [0, 0, 255, 255])
        #expect(try colors(renderer.renderOffscreen(next)) == [blue, white, white])
    }
}
#endif
