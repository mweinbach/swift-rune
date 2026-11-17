import Testing
@testable import Rune

@Suite("Runtime image atlas growth")
struct RuntimeAtlasGrowthTests {
    private func sprite(width: Int, height: Int, marker: UInt8) -> RGBA8Atlas {
        var texels = [UInt8](repeating: 0, count: width * height * 4)
        let middle = (width * (height / 2) + width / 2) * 4
        texels.replaceSubrange(middle..<(middle + 4), with: [marker, 196, 21, 47])
        return RGBA8Atlas(width: width, height: height, texels: texels)
    }

    private func center(_ atlas: RGBA8Atlas, _ edges: SIMD4<Float>) -> [UInt8] {
        let x = Int(edges.x) + Int(edges.z - edges.x) / 2
        let y = Int(edges.y) + Int(edges.w - edges.y) / 2
        guard x >= 0, x < atlas.width, y >= 0, y < atlas.height else { return [] }
        let start = 4 * (y * atlas.width + x)
        return Array(atlas.texels[start..<(start + 4)])
    }

    private func center(_ atlas: RGBA8Atlas, instance: RenderInstance) -> [UInt8] {
        let uv = instance.uv // RenderFrame encodes an origin and size in texels.
        return center(atlas, SIMD4(uv.x, uv.y, uv.x + uv.z, uv.y + uv.w))
    }

    @Test func wideAndTallSpritesKeepStableTexelsWithoutExpandingBothAxesOnEveryShelf() {
        var packer = Runtime<Int>.ImageAtlasPacker()
        let banner = sprite(width: 503, height: 3, marker: 1)
        let column = sprite(width: 3, height: 503, marker: 2)
        let bannerEdges = packer.insert(banner)
        let columnEdges = packer.insert(column)
        var strips: [SIMD4<Float>] = []
        for marker in UInt8(3)..<15 {
            strips.append(packer.insert(sprite(width: 503, height: 3, marker: marker)))
        }

        // The column and all thirteen strips fit in a single 1024-square texture.
        #expect(packer.atlas.width * packer.atlas.height <= 1024 * 1024)
        #expect(packer.insert(banner) == bannerEdges)
        #expect(packer.insert(column) == columnEdges)
        #expect(center(packer.atlas, bannerEdges) == [1, 196, 21, 47])
        #expect(center(packer.atlas, columnEdges) == [2, 196, 21, 47])
        for (i, edges) in strips.enumerated() {
            #expect(center(packer.atlas, edges) == [UInt8(i + 3), 196, 21, 47])
        }
    }

    @Test func passthroughSpriteCanSpanTheMaximumTextureDimension() {
        for size in [SIMD2(16_384, 1), SIMD2(1, 16_384)] {
            var packer = Runtime<Int>.ImageAtlasPacker()
            let edges = packer.insert(sprite(width: size.x, height: size.y, marker: 185))
            #expect(Int(edges.z - edges.x) == size.x && Int(edges.w - edges.y) == size.y)
            #expect(packer.atlas.width <= 16_384 && packer.atlas.height <= 16_384)
            #expect(center(packer.atlas, edges) == [185, 196, 21, 47])
        }
    }

    @Test func changingImagePayloadsReuseSpaceAcrossProductionFrames() throws {
        let anchor = sprite(width: 9, height: 7, marker: 226)
        let runtime = Runtime(state: UInt8(0), viewport: Vec2(60, 20), pixelScale: 1) { phase, _ in
            el().size(60, 20)
                .child(image(anchor).key("anchor").absolute(x: 0, y: 0).size(9, 7).cache())
                .child(image(sprite(width: 31, height: 17, marker: phase))
                    .key("changing").absolute(x: 16, y: 0).size(31, 17).cache())
        }
        let first = runtime.renderFrame(at: 0)
        let firstSprites = first.instances.filter { $0.params.y == KIND_IMAGE }
        let firstLayers = first.instances.filter { $0.params.y == KIND_LAYER && $0.params.w == 1 }
        try #require(firstSprites.count == 2)
        try #require(firstLayers.count == 2)
        var signatures = [firstSprites[1].uv: firstLayers[1].uv]
        var reusedSlot = false

        for phase in UInt8(1)...96 {
            let t = Double(phase)
            runtime.update(at: t) { state, tx in state = phase; tx.settle() }
            let frame = runtime.renderFrame(at: t)
            let sprites = frame.instances.filter { $0.params.y == KIND_IMAGE }
            let layers = frame.instances.filter { $0.params.y == KIND_LAYER && $0.params.w == 1 }
            try #require(sprites.count == 2)
            try #require(layers.count == 2)
            #expect(layers[0].uv == firstLayers[0].uv)
            if let previous = signatures.updateValue(layers[1].uv, forKey: sprites[1].uv) {
                reusedSlot = true
                #expect(previous != layers[1].uv)
            }
            #expect(center(frame.images, instance: sprites[0]) == [226, 196, 21, 47])
            #expect(center(frame.images, instance: sprites[1]) == [phase, 196, 21, 47])
            #expect(frame.images.width <= 128 && frame.images.height <= 128)
        }
        // A submitted frame holds the atlas bytes and positions it was built with.
        #expect(center(first.images, instance: firstSprites[1]) == [0, 196, 21, 47])
        #expect(reusedSlot)
    }

    @Test func changingDimensionsReleaseUnusableRectanglesBetweenPaints() {
        var packer = Runtime<Int>.ImageAtlasPacker()
        for phase in 0..<96 {
            let width = 40 + phase % 32
            let height = 40 + phase / 32
            packer.beginPaint()
            let edges = packer.insert(sprite(width: width, height: height, marker: UInt8(phase)))
            #expect(center(packer.atlas, edges) == [UInt8(phase), 196, 21, 47])
            #expect(packer.atlas.width * packer.atlas.height <= 256 * 256)
            packer.finishPixelPaint()
        }
    }

    @Test func previousBitmapCanReappearAfterAnotherDrawReusesItsSlot() {
        var packer = Runtime<Int>.ImageAtlasPacker()
        let first = sprite(width: 12, height: 9, marker: 62)
        let changed = sprite(width: 12, height: 9, marker: 164)
        packer.beginPaint()
        let original = packer.insert(first)
        let previous = packer.atlas
        packer.finishPixelPaint()

        packer.beginPaint()
        let replacement = packer.insert(changed)
        let reappearing = packer.insert(first)
        #expect(replacement == original)
        #expect(replacement != reappearing)
        #expect(center(packer.atlas, replacement) == [164, 196, 21, 47])
        #expect(center(packer.atlas, reappearing) == [62, 196, 21, 47])
        #expect(center(previous, original) == [62, 196, 21, 47])
    }

    @Test func foldedOpacityGroupKeepsTheImageSourceSize() throws {
        let payload = sprite(width: 9, height: 7, marker: 42)
        let runtime = Runtime(state: (), viewport: Vec2(9, 7), pixelScale: 1) { _, _ in
            el().size(9, 7).opacity(0.5).child(image(payload).size(9, 7))
        }
        let frame = runtime.renderFrame(at: 0)
        let instance = try #require(frame.instances.first { $0.params.y == KIND_IMAGE })
        #expect(instance.uv.z == 9 && instance.uv.w == 7)
        #expect(center(frame.images, instance: instance) == [42, 196, 21, 47])
    }

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    @Test func cachedGPUImageShowsEachReplacement() throws {
        let renderer: OffscreenGPURenderer
        do { renderer = try OffscreenGPURenderer() }
        catch OffscreenRenderError.unavailable { return }
        let runtime = Runtime(state: UInt8(0), viewport: Vec2(4, 4), pixelScale: 1) { red, _ in
            image(RGBA8Atlas(width: 1, height: 1, texels: [red, 0, 0, 255]))
                .key("picture").size(4, 4).cache()
        }
        for (i, red) in [UInt8(248), 17, 96, 207, 53, 151].enumerated() {
            let t = Double(i)
            runtime.update(at: t) { state, tx in state = red; tx.settle() }
            let frame = try renderer.frame(runtime, at: t)
            let displayed = try renderer.renderOffscreen(frame)
            let pixel = displayed.pixel(x: 2, y: 2)
            #expect(abs(Int(pixel.x) - Int(red)) <= 1 && pixel.y == 0 && pixel.z == 0 && pixel.w == 255)
        }
    }
    #endif
}
