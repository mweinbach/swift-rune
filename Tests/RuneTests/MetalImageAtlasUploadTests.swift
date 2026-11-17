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

        // Mark one unused padding texel inside the previous update. Its survival
        // distinguishes a true no-op from uploading that same rectangle again.
        let firstSlot = leftEdges.x < rightEdges.x ? leftEdges : rightEdges
        let padding = MTLRegionMake2D(firstSlot.z, firstSlot.y, 1, 1)
        let marker: [UInt8] = [18, 52, 86, 255]
        texture.replace(region: padding, mipmapLevel: 0, withBytes: marker, bytesPerRow: 4)
        let repeatFrame = runtime.renderFrame(at: 3)
        #expect(repeatFrame.imageRevision == both.imageRevision)
        #expect(try colors(renderer.renderOffscreen(repeatFrame)) == [blue, white, red])
        var unchanged = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&unchanged, bytesPerRow: 4, from: padding, mipmapLevel: 0)
        #expect(unchanged == marker)
        #expect(renderer.uploader.imageTexture === texture)

        let wide = initial.images.width + 2
        left.set(width: UInt32(wide), height: 2, rgba: [UInt8](repeating: 255, count: wide * 2 * 4))
        let grown = runtime.renderFrame(at: 4)
        #expect(grown.images.width > initial.images.width)
        #expect(try colors(renderer.renderOffscreen(grown)) == [white, white, red])
        #expect(try uploadedEdges(renderer) == SIMD4(0, 0, grown.images.width, grown.images.height))
        #expect(renderer.uploader.imageTexture !== texture)
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
