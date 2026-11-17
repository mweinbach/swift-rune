import Testing
@testable import Rune

@Suite("Image pages from ordinary Rune views")
struct RuntimeImagePagesTests {
    private func pixel(_ index: Int) -> SIMD4<UInt8> {
        SIMD4(UInt8(index + 3), UInt8(250 - index), UInt8(index ^ 83), 255)
    }

    private func bitmap(side: Int, color: SIMD4<UInt8>) -> RGBA8Atlas {
        let words = [SIMD4<UInt8>](repeating: color, count: side * side)
        return RGBA8Atlas(width: side, height: side, texels: words.withUnsafeBytes { Array($0) })
    }

    @MainActor @Test func imageGridKeepsPageOrderAndOnlyTheEditedPageChanges() throws {
        let count = 77, columns = 11, cell = 5, side = 160
        let changed = 45
        let payloads = (0..<count).map { bitmap(side: side, color: pixel($0)) }
        let stream = Pixels()
        stream.set(width: UInt32(side), height: UInt32(side), rgba: payloads[changed].texels)
        let runtime = Runtime<Void>(state: (), viewport: Vec2(Float(columns * cell), 35), pixelScale: 1) { _, _ in
            el().size(Float(columns * cell), 35).children((0..<count).map { index -> El<Void> in
                let tile: El<Void> = index == changed ? el().pixels(stream) : image(payloads[index])
                return tile.key("image-\(index)").size(Float(cell), Float(cell))
                    .absolute(x: Float(index % columns * cell), y: Float(index / columns * cell))
            })
        }

        func check(_ output: Frame, replacement: SIMD4<UInt8>?) {
            var expected = [UInt8]()
            expected.reserveCapacity(55 * 35 * 4)
            for y in 0..<35 {
                for x in 0..<55 {
                    let index = (y / cell) * columns + x / cell
                    let color = (index == changed ? replacement : nil) ?? pixel(index)
                    expected.append(contentsOf: [color.x, color.y, color.z, color.w])
                }
            }
            #expect(output.width == 55 && output.height == 35)
            #expect(output.rgba == expected)
        }

        let first = runtime.renderFrame(at: 0)
        let images = first.instances.filter { $0.params.y == KIND_IMAGE }
        try #require(images.count == count)
        #expect(images.map { Int($0.params.x) } == (0..<count).map { $0 / 36 })
        #expect(first.imagePages.count == 3 && first.imagePageRevisions.count == 3)
        #expect(first.imagePages.map(\.width) == [1024, 1024, 1024])
        #expect(first.imagePages.map(\.height) == [1024, 1024, 256])
        let same = runtime.renderFrame(at: 0.01)
        #expect(first.imagePageRevisions == same.imagePageRevisions)
        let retainedTable = first.imagePages.withUnsafeBufferPointer { first in
            same.imagePages.withUnsafeBufferPointer { previous in first.baseAddress == previous.baseAddress }
        }
        #expect(retainedTable)
        let oldCPU = runtime.frame(at: 0.02)
        check(try RuneRef.render(oldCPU), replacement: nil)

        let replacement = SIMD4<UInt8>(251, 31, 77, 255)
        stream.set(width: UInt32(side), height: UInt32(side), rgba: bitmap(side: side, color: replacement).texels)
        let updated = runtime.renderFrame(at: 0.03)
        try #require(updated.imagePageRevisions.count == 3)
        #expect(first.imagePageRevisions[0] == updated.imagePageRevisions[0])
        #expect(first.imagePageRevisions[1] != updated.imagePageRevisions[1])
        #expect(first.imagePageRevisions[2] == updated.imagePageRevisions[2])
        let patch = try #require(updated.imagePagePatches[1])
        #expect(patch.fromRevision == first.imagePageRevisions[1])
        #expect(patch.edges == SIMD4(3 * side, side, 4 * side, 2 * side))
        check(try RuneRef.render(runtime.frame(at: 0.04)), replacement: replacement)
        check(try RuneRef.render(oldCPU), replacement: nil)

        #if canImport(Metal)
        let renderer: MetalRenderer
        do { renderer = try MetalRenderer() }
        catch MetalRenderer.RendererError.metalUnavailable { return }
        check(try renderer.renderOffscreen(first), replacement: nil)
        let uploaded = renderer.uploader.imageUploadBytes
        #expect(uploaded == 9 * 1024 * 1024)
        check(try renderer.renderOffscreen(same), replacement: nil)
        #expect(renderer.uploader.imageUploadBytes == uploaded)
        check(try renderer.renderOffscreen(updated), replacement: replacement)
        #expect(renderer.uploader.imageUploadBytes - uploaded == UInt64(side * side * 4))
        check(try renderer.renderOffscreen(first), replacement: nil)
        #endif
        #if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
        try withTestGLTarget { gl, draw in
            for (frame, color) in [(first, nil as SIMD4<UInt8>?), (same, nil), (updated, replacement), (first, nil)] {
                check(try draw(frame.width, frame.height) { try gl.draw(frame) }, replacement: color)
            }
        }
        #endif
    }

    @Test func sharedBitmapStorageDetachesOnWriteAndDeduplicatesEqualAllocations() {
        var packer = Runtime<Void>.ImageAtlasPacker()
        var source = bitmap(side: 12, color: pixel(3))
        let first = packer.insert(source)
        let retained = source
        #expect(packer.insert(bitmap(side: 12, color: pixel(3))) == first)
        let offset = (6 * source.width + 6) * 4
        source.texels[offset] = 200
        let changed = packer.insert(source)
        #expect(changed != first)
        #expect(packer.insert(retained) == first)
        let page = packer.atlas(at: first.page)
        let retainedOffset = ((Int(first.edges.y) + 6) * page.width + Int(first.edges.x) + 6) * 4
        #expect(page.texels[retainedOffset] == pixel(3).x)
    }

    @Test func prependingAnImageLeavesTheFullVisiblePageResident() {
        var packer = Runtime<Void>.ImageAtlasPacker()
        let body = (0..<4).map { bitmap(side: 512, color: pixel($0)) }
        packer.beginPaint()
        let first = body.map { packer.insert($0) }
        var previous = RenderFrame(width: 10, height: 10)
        packer.publish(into: &previous)
        packer.finishPixelPaint()

        packer.beginPaint()
        let leading = packer.insert(bitmap(side: 512, color: pixel(4)))
        #expect(leading.page == 1)
        #expect(body.map { packer.insert($0) } == first)
        var next = RenderFrame(width: 10, height: 10)
        packer.publish(into: &next)
        #expect(previous.imagePageRevisions[0] == next.imagePageRevisions[0])
        packer.finishPixelPaint()
    }

    @Test func resizedStreamCannotRecycleAnEarlierDrawWithinTheSamePaint() throws {
        var packer = Runtime<Void>.ImageAtlasPacker()
        var playback = ImagePlayback()
        let stream = Pixels()
        stream.set(width: 4, height: 4, rgba: [UInt8](repeating: 155, count: 64))
        packer.beginPaint()
        let initial = playback.sample(stream, at: 0)
        let old = packer.insert(try #require(initial), for: stream.id, drawnSize: SIMD2(4, 4))
        stream.set(width: 3, height: 3, rgba: [UInt8](repeating: 88, count: 36))
        let resized = playback.sample(stream, at: 0)
        _ = packer.insert(try #require(resized), for: stream.id, drawnSize: SIMD2(3, 3))
        let other = packer.insert(RGBA8Atlas(width: 4, height: 4, texels: [UInt8](repeating: 44, count: 64)))
        #expect(other != old)
        let first = packer.atlas(at: old.page)
        let offset = 4 * (Int(old.edges.y) * first.width + Int(old.edges.x))
        #expect(first.texels[offset] == 155)
        packer.finishPixelPaint()
        packer.beginPaint()
        let recycled = packer.insert(RGBA8Atlas(width: 4, height: 4, texels: [UInt8](repeating: 12, count: 64)))
        #expect(recycled == old)
    }

    @Test func independentLongTexturesAndInvalidInputCannotReadNeighborPixels() throws {
        var packer = Runtime<Void>.ImageAtlasPacker()
        let wide = RGBA8Atlas(width: 16_384, height: 1,
                              texels: [UInt8](repeating: 255, count: 16_384 * 4))
        let tall = RGBA8Atlas(width: 1, height: 16_384,
                              texels: [UInt8](repeating: 127, count: 16_384 * 4))
        let a = packer.insert(wide)
        let b = packer.insert(tall)
        let invalid = packer.insert(RGBA8Atlas(width: Int.max, height: 7, texels: []))
        #expect(a.page != b.page)
        #expect(packer.atlas(at: a.page) == wide)
        #expect(packer.atlas(at: b.page) == tall)
        let empty = packer.atlas(at: invalid.page)
        let index = (Int(invalid.edges.y) * empty.width + Int(invalid.edges.x)) * 4
        #expect(Array(empty.texels[index..<(index + 4)]) == [0, 0, 0, 0])
    }
}
