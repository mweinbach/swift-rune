import Testing
@testable import Rune

@Suite("Windfoil CPU glyphs")
struct CpuBootOutlineTests {
    private static let size = (40, 28)
    static func frame(mode: Float, lcd: Bool, layer: Bool) throws -> RenderFrame {
        let path: [OutlinePathCommand] = [
            .moveTo(SIMD2(0, 0)), .lineTo(SIMD2(3, 0)), .lineTo(SIMD2(3, 5)),
            .lineTo(SIMD2(6, 5)), .quadTo(SIMD2(12, 5), SIMD2(12, 9)),
            .quadTo(SIMD2(12, 13), SIMD2(5, 13)), .lineTo(SIMD2(0, 13)), .close,
            .moveTo(SIMD2(3, 8)), .lineTo(SIMD2(3, 10)), .lineTo(SIMD2(6, 10)),
            .quadTo(SIMD2(9, 10), SIMD2(9, 9)), .quadTo(SIMD2(9, 8), SIMD2(6, 8)), .close
        ]
        let store = OutlineStore()
        let outline = try #require(OutlineBuilder.build(commands: path, upem: 14))
        guard case let .outline(glyph) = store.glyph(.init(font: 1, glyph: 1), build: { outline }) else {
            throw FixtureError.missingOutline
        }
        let clip = SIMD4<Float>(8.25, 4.25, 27.75, 23.1)
        let ink = RenderInstance(rect: SIMD4(0, 0, 40, 28), radii: SIMD4(4.35, 23.4, 0.88, 1.65),
            fill: SIMD4(0.5, 0.14, 0.28, 0.67), border: SIMD4(Float(glyph.record), 0, 0.16, mode),
            params: SIMD4(0, KIND_GLYPH, 0, 0.85), clip: clip)
        let instances: [RenderInstance] = layer ?
            [.beginLayer(bounds: SIMD4(0, 0, 40, 28), clip: NO_CLIP, spec: LayerSpec(opacity: 0.75)), ink, .endLayer()] : [ink]
        return RenderFrame(width: Self.size.0, height: Self.size.1, srgbBlend: true,
                           clearColor: SIMD4(0.08, 0.3, 0.5, 1), outlines: store.snapshot(requestsLCD: lcd),
                           instances: instances)
    }

    private enum FixtureError: Error { case missingOutline }

    // Digests of complete RGBA frames from the Rust cpu_boot painter at 842c28c2.
    @Test("CPU frames match Rust for fractional clip, zoom, LCD, layers and wide masks")
    func renderedFrames() throws {
        let cases: [(mode: Float, lcd: Bool, layer: Bool, digest: UInt64)] = [
            (0, false, false, 0xafed123054d3352c),
            (2, true, false, 0x917b48b8e9f92e0f),
            (2, false, false, 0xafed123054d3352c),
            (2, true, true, 0x2b67af6b13cf96ad),
            (0, false, true, 0x2b67af6b13cf96ad),
            (3, false, false, 0xff7ac67f2f8393cb),
        ]
        for sample in cases {
            let frame = try Self.frame(mode: sample.mode, lcd: sample.lcd, layer: sample.layer)
            let scene = CpuBootScene(frame: frame)
            #expect(scene.needsGpu() == nil)
            #expect(scene.lcd == sample.lcd)
            var target = CpuBootTarget(width: frame.width, height: frame.height)
            _ = try CpuBoot.paint(scene, into: &target, threads: 1)
            let digest = target.toRGBA8Tight().reduce(UInt64(0xcbf29ce484222325)) {
                ($0 ^ UInt64($1)) &* 0x100000001b3
            }
            #expect(digest == sample.digest)
        }
    }

    @Test("Slug requires the GPU and an adapter can disable subpixel blending")
    func unsupportedCoverageAndLCDOverride() throws {
        let frame = try Self.frame(mode: 1, lcd: true, layer: false)
        let scene = CpuBootScene(frame: frame, lcd: false)
        #expect(!scene.lcd)
        #expect(scene.needsGpu() == .outlineGlyph)
    }
}
