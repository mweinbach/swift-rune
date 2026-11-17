import RuneRef
import Testing

struct NativeGlyphSamplingTests {
    private let atlas = R8Atlas(width: 4, height: 3, texels: [
        255, 16, 240, 255,
        255, 32, 208, 255,
        255, 255, 255, 255,
    ])
    private let uv = SIMD4<Float>(0.25, 0, 0.75, 2.0 / 3.0)
    private let clip = SIMD4<Float>(-10, -10, 20, 20)

    private func coverage(_ glyph: Primitive, at x: Float, _ y: Float) -> Float {
        RefShader.evaluatePrimitive(
            glyph, fragCoord: SIMD2(x, y), glyphs: atlas, images: RGBA8Atlas(), srgbBlend: true
        ).w
    }

    @Test func fractionalNativeQuadReadsOneMaskTexelPerPixel() {
        let rect = SIMD4<Float>(-0.25, 0.375, 2, 2)
        let exact = Primitive.glyph(rect: rect, uv: uv, color: SIMD4(repeating: 1), clip: clip, nativeSize: true)
        let filtered = Primitive.glyph(rect: rect, uv: uv, color: SIMD4(repeating: 1), clip: clip)
        #expect(coverage(exact, at: 0.5, 0.5) == Float(16) / 255)
        #expect(coverage(exact, at: 1.5, 1.5) == Float(208) / 255)
        #expect(coverage(filtered, at: 0.5, 0.5) > coverage(exact, at: 0.5, 0.5))

        var onPixelCenter = exact
        onPixelCenter.rect = SIMD4(-0.5, 0.5, 2, 2)
        #expect(coverage(onPixelCenter, at: -0.5, 0.5) == Float(16) / 255)
        #expect(coverage(onPixelCenter, at: 1.5, 0.5) == 0)
        #expect(coverage(onPixelCenter, at: 0.5, 2.5) == 0)

        var fractionalUV = exact
        fractionalUV.uv.x = 1.75 / Float(atlas.width)
        #expect(coverage(fractionalUV, at: 0.5, 0.5) == Float(16) / 255)
    }

    @Test func oracleConversionPreservesSamplingAndRotation() {
        for native in [true, false] {
            for turn: Float in [0, 0.37] {
                let rect = SIMD4<Float>(-0.25, 0.375, native ? 2 : 4, 2)
                let glyph = Primitive.glyph(rect: rect, uv: uv, color: SIMD4(repeating: 1),
                                           clip: clip, turn: turn, nativeSize: native)
                let oracle = OraclePrimitive.fromInstance(glyph, atlasWidth: 4, atlasHeight: 3)
                #expect(oracle.uv == [1, 0, native ? 0 : 2, native ? 0 : 2])
                #expect(oracle.params[0] == turn)
                let replay = oracle.toInstance(atlasWidth: 4, atlasHeight: 3)
                #expect(replay == glyph)
                let rawAtlas = OracleAtlas(width: 4, height: 3, data: atlas.texels)
                let expected = OracleShader.fragment(oracle, atlas: rawAtlas, screen: (0.5, 1.5)).3
                #expect(abs(coverage(replay, at: 0.5, 1.5) - expected) < 0.00001)
            }
        }
    }
}
