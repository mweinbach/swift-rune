#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import RuneRef
import Testing
@testable import Rune

@MainActor
@Suite("OpenGL atlas uploads")
struct PortableGLAtlasPatchTests {
    @Test("Unchanged multi-page glyph snapshots share their backing storage")
    func unchangedGlyphPages() throws {
        let atlas = GlyphAtlas(width: 16, height: 16)
        let ink = [UInt8](repeating: 170, count: 100)
        for _ in 0..<2 { _ = try #require(atlas.placeMask(width: 10, height: 10, bitmap: ink)) }
        let first = atlas.compositedAtlas()
        let same = atlas.compositedAtlas()
        #expect(first.height == 32)
        let sharesBacking = first.texels.withUnsafeBufferPointer { a in
            same.texels.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        #expect(sharesBacking)
        _ = try #require(atlas.placeMask(width: 10, height: 10, bitmap: ink))
        let expanded = atlas.compositedAtlas()
        #expect(expanded.height == 48)
        #expect(first.texels.elementsEqual(expanded.texels.prefix(first.texels.count)))
    }

    @Test("Patches inside odd-width R8 and RGBA8 atlases preserve surrounding texels")
    func atlasPatches() throws {
        let width = 13, height = 9
        let clip = SIMD4<Float>(0, 0, Float(width * 2), Float(height))
        let uv = SIMD4<Float>(0, 0, 1, 1)
        let color = SIMD4<Float>(repeating: 1)
        var scene = RefScene(
            width: width * 2, height: height, srgbBlend: true, clearColor: SIMD4(0, 0, 0, 1),
            glyphs: R8Atlas(width: width, height: height, texels: [UInt8](repeating: 80, count: width * height)),
            images: RGBA8Atlas(width: width, height: height, texels: [UInt8](repeating: 130, count: 4 * width * height)),
            primitives: [
                .glyph(rect: SIMD4(0, 0, Float(width), Float(height)), uv: uv, color: color, clip: clip),
                .image(rect: SIMD4(Float(width), 0, Float(width), Float(height)), uv: uv, clip: clip)
            ]
        )

        try withTestGLRenderer { _, render in
            let initial = try render(scene)
            for y in 2..<6 {
                for x in 4..<9 {
                    scene.glyphs.texels[y * width + x] = UInt8(200 + y)
                }
            }
            for y in 3..<6 {
                for x in 6..<10 {
                    let i = 4 * (y * width + x)
                    scene.images.texels[i] = UInt8(240 - x)
                    scene.images.texels[i + 3] = 255
                }
            }
            let patched = try render(scene)
            let reference = try RuneRef.render(scene)
            #expect(initial != patched)
            #expect(RuneRef.compare(scene: scene, expected: reference, actual: patched, channelTolerance: 2).passed)
            let repeated = try render(scene)
            #expect(repeated == patched)
        }
    }
}
#endif
