import Testing
@testable import Rune

@Suite("CPU boot retained atlas damage")
struct CpuBootAtlasDamageTests {
    private let width = Int(CpuBootBin.tileW) * 3
    private let height = Int(CpuBootBin.tileH)

    private func image(page: Int, at x: Int, sourceX: Float = 0) -> RenderInstance {
        RenderInstance(rect: SIMD4(Float(x + 4), 0, 8, 8), fill: SIMD4(repeating: 1),
                       params: SIMD4(Float(page), KIND_IMAGE, 0, 1), uv: SIMD4(sourceX, 0, 1, 1), clip: NO_CLIP)
    }

    private func glyph(at x: Int) -> RenderInstance {
        RenderInstance(rect: SIMD4(Float(x), 0, 2, 2), fill: SIMD4(repeating: 1),
                       params: SIMD4(0, KIND_GLYPH, 0, 1), uv: .zero, clip: NO_CLIP)
    }

    private func verify(_ target: CpuBootTarget, scene: CpuBootScene) throws {
        var oracle = CpuBootTarget(width: scene.size.0, height: scene.size.1)
        _ = try CpuBoot.paint(scene, into: &oracle, threads: 1)
        #expect(oracle.pixels == target.pixels)
    }

    @Test("Independent image pages update only the sampled tile, including hand-built frames")
    func imagePageMutation() throws {
        let tile = Int(CpuBootBin.tileW)
        let red: [UInt8] = [255, 0, 0, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255]
        let painter = CpuPainter(threads: 1)
        var target = CpuBootTarget(width: width, height: height)
        var frame = RenderFrame(width: width, height: height, srgbBlend: true,
            imagePages: [RGBA8Atlas(width: 1, height: 1, texels: red),
                         RGBA8Atlas(width: 2, height: 1, texels: green + green)],
            instances: [image(page: 0, at: 0), image(page: 1, at: tile),
                        image(page: 1, at: tile * 2, sourceX: 1)])
        _ = try painter.paint(CpuBootScene(frame: frame), into: &target)
        #expect(Array(target.pixels[16..<20]) == [0, 0, 255, 255])
        #expect(Array(target.pixels[(tile + 4) * 4..<(tile + 5) * 4]) == green)
        // Keep the same nominal revision. Public RenderFrames can replace the backing bytes.
        frame.imagePages[1].texels.replaceSubrange(4..<8, with: blue)
        let changed = CpuBootScene(frame: frame)
        let update = try painter.paint(changed, into: &target)
        #expect(update.dirtyTiles == 1)
        #expect(update.report.threads == 1)
        #expect(Array(target.pixels[(tile * 2 + 4) * 4..<(tile * 2 + 5) * 4]) == [255, 0, 0, 255])
        try verify(target, scene: changed)
        let clean = try painter.paint(changed, into: &target)
        #expect(clean.dirtyTiles == 0 && clean.report.threads == 0)
    }

    @Test("Skipped page revisions invalidate all sampled sprites even when the latest patch is disjoint")
    func skippedPatch() throws {
        let tile = Int(CpuBootBin.tileW)
        let painter = CpuPainter(threads: 1)
        var target = CpuBootTarget(width: width, height: height)
        var frame = RenderFrame(width: width, height: height, srgbBlend: true,
            images: RGBA8Atlas(width: 2, height: 1, texels: [0, 0, 0, 255, 0, 0, 0, 255]),
            instances: [image(page: 0, at: 0), image(page: 0, at: tile, sourceX: 1)])
        frame.imagePageRevisions = [10]
        _ = try painter.paint(CpuBootScene(frame: frame), into: &target)
        frame.images.texels[0] = 255
        frame.imagePageRevisions = [11]
        frame.imagePagePatches = [ImageAtlasPatch(fromRevision: 10, edges: SIMD4(0, 0, 1, 1))]
        let partial = CpuBootScene(frame: frame)
        #expect(try painter.paint(partial, into: &target).dirtyTiles == 1)
        #expect(try painter.paint(partial, into: &target).dirtyTiles == 0)

        frame.images.texels = [0, 255, 0, 255, 0, 0, 255, 255]
        frame.imagePageRevisions = [13]
        frame.imagePagePatches = [ImageAtlasPatch(fromRevision: 12, edges: SIMD4(1, 0, 2, 1))]
        let latest = CpuBootScene(frame: frame)
        #expect(try painter.paint(latest, into: &target).dirtyTiles == 2)
        try verify(target, scene: latest)
    }

    @Test("Mask replacement reaches a retained target and a clear-only change fills every uncovered tile")
    func glyphAndClear() throws {
        let painter = CpuPainter(threads: 1)
        var target = CpuBootTarget(width: width, height: height)
        var frame = RenderFrame(width: width, height: height, srgbBlend: true,
            glyphs: R8Atlas(width: 2, height: 2, texels: [255, 0, 0, 0]), instances: [glyph(at: 0)])
        _ = try painter.paint(CpuBootScene(frame: frame), into: &target)
        #expect(Array(target.pixels[0..<4]) == [255, 255, 255, 255])
        frame.glyphs.texels = [0, 0, 0, 255]
        frame.glyphGeneration += 1
        let glyphScene = CpuBootScene(frame: frame)
        #expect(try painter.paint(glyphScene, into: &target).dirtyTiles == 1)
        #expect(Array(target.pixels[0..<4]) == [0, 0, 0, 255])
        try verify(target, scene: glyphScene)
        frame.clearColor = SIMD4(1, 0, 0, 1)
        let clearScene = CpuBootScene(frame: frame)
        let clearDamage = try painter.paint(clearScene, into: &target)
        #expect(clearDamage.dirtyTiles == clearDamage.tiles)
        try verify(target, scene: clearScene)
        #expect(Array(target.pixels.suffix(4)) == [0, 0, 255, 255])
        #expect(try painter.paint(clearScene, into: &target).rects.isEmpty)
    }

    @Test("Background clear remains visible through a rounded clip, while an opaque central tile stays clean")
    func clearBehindRoundedClip() throws {
        let w = Int(CpuBootBin.tileW) * 3, h = Int(CpuBootBin.tileH) * 3
        let clip = SIMD4<Float>(0, 0, Float(w), Float(h))
        var box = RenderInstance(rect: clip, fill: SIMD4(0, 0, 1, 1),
                                 params: SIMD4(0, KIND_RECT, 0, 1), clip: clip)
        box.fade.w = packClipRadii(clip: clip, radii: SIMD4(repeating: 40))
        var scene = CpuBootScene(instances: [box], size: (w, h))
        let painter = CpuPainter(threads: 1)
        var target = CpuBootTarget(width: w, height: h)
        _ = try painter.paint(scene, into: &target)
        scene.clear = SIMD4(1, 0, 0, 1)
        let changed = try painter.paint(scene, into: &target)
        #expect(changed.dirtyTiles > 0 && changed.dirtyTiles < changed.tiles)
        #expect(Array(target.pixels[0..<4]) == [0, 0, 255, 255])
        try verify(target, scene: scene)
    }

    @Test("Mask pages keep independent row strides and damage")
    func independentGlyphPages() throws {
        let tile = Int(CpuBootBin.tileW)
        var second = glyph(at: tile)
        second.params.z = 1
        let painter = CpuPainter(threads: 1)
        var target = CpuBootTarget(width: width, height: height)
        var frame = RenderFrame(width: width, height: height, srgbBlend: true,
            glyphPages: [R8Atlas(width: 2, height: 2, texels: [255, 0, 0, 255]),
                         R8Atlas(width: 3, height: 2, texels: [0, 0, 0, 255, 0, 0])],
            instances: [glyph(at: 0), second])
        _ = try painter.paint(CpuBootScene(frame: frame), into: &target)
        #expect(target.pixels[0] == 255)
        #expect(target.pixels[tile * 4] == 0)
        #expect(target.pixels[(width + tile) * 4] == 255)
        frame.glyphPages[1].texels = [255, 0, 0, 0, 0, 0]
        let next = CpuBootScene(frame: frame)
        #expect(try painter.paint(next, into: &target).dirtyTiles == 1)
        #expect(target.pixels[tile * 4] == 255)
        #expect(target.pixels[(width + tile) * 4] == 0)
        try verify(target, scene: next)
        #expect(try painter.paint(next, into: &target).rects.isEmpty)
    }

    @Test("Manual signed UVs and changed glyph masks need no runtime revision")
    func directSceneSignedCrop() throws {
        let tile = Int(CpuBootBin.tileW)
        var crop = image(page: 0, at: tile)
        crop.uv = SIMD4(2, 1, -2, -1)
        let painter = CpuPainter(threads: 1)
        var target = CpuBootTarget(width: width, height: height)
        var scene = CpuBootScene(instances: [glyph(at: 0), crop],
            glyphPages: [[255, 255, 255, 255]], glyphPageWidth: 2, glyphPageHeight: 2,
            images: [CpuBootImage(width: 2, data: [255, 0, 0, 255, 0, 0, 255, 255])],
            size: (width, height))
        _ = try painter.paint(scene, into: &target)
        scene.glyphPages[0][1] = 0
        scene.images[0].data[4] = 255
        #expect(try painter.paint(scene, into: &target).dirtyTiles == 2)
        try verify(target, scene: scene)
        #expect(try painter.paint(scene, into: &target).dirtyTiles == 0)
    }
}
