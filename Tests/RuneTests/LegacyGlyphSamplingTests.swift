import RuneRef
import Testing
@testable import Rune

@MainActor
@Suite("Reference scene glyph atlas sampling")
struct LegacyGlyphSamplingTests {
    private func scene(srgbBlend: Bool) -> RefScene {
        let clip = SIMD4<Float>(0, 0, 24, 14)
        let atlas = R8Atlas(width: 7, height: 4, texels: [
            55, 55,  55,  55, 240, 240, 240,
            55, 79, 163, 221, 240, 240, 240,
            55, 91, 193, 107, 240, 240, 240,
            55, 55,  55,  55, 240, 240, 240
        ])
        let uv = SIMD4<Float>(1 / 7, 1 / 4, 4 / 7, 3 / 4)
        let fractionalUV = SIMD4<Float>(1.75 / 7, 1.75 / 4, 4.75 / 7, 3.75 / 4)
        let white = SIMD4<Float>(repeating: 1)
        return RefScene(width: 24, height: 14, srgbBlend: srgbBlend, clearColor: SIMD4(0, 0, 0, 1),
                        glyphs: atlas, primitives: [
                            .glyph(rect: SIMD4(-0.5, 0.5, 3, 2), uv: uv, color: white, clip: clip, nativeSize: true),
                            .glyph(rect: SIMD4(4.25, 1.25, 3, 2), uv: uv, color: white, clip: clip, nativeSize: true),
                            .glyph(rect: SIMD4(4.25, 5.25, 3, 2), uv: uv, color: white, clip: clip),
                            .glyph(rect: SIMD4(4.25, 9.25, 3, 2), uv: fractionalUV, color: white, clip: clip, nativeSize: true),
                            .glyph(rect: SIMD4(9.25, 2.25, 6, 4), uv: uv, color: white, clip: clip),
                            .glyph(rect: SIMD4(16.25, 2.25, 3, 2), uv: uv, color: white, clip: clip, turn: 0.4, nativeSize: true)
                        ])
    }

    private func check(srgbBlend: Bool, render: (RefScene) throws -> Frame) throws {
        let fixture = scene(srgbBlend: srgbBlend)
        let expected = try RuneRef.render(fixture)
        let rendered = try render(fixture)
        if srgbBlend {
            #expect(rendered.pixel(x: 0, y: 0).x == 163)
            #expect(rendered.pixel(x: 1, y: 1).x == 107)
            #expect(rendered.pixel(x: 2, y: 1).x == 0)
            #expect(rendered.pixel(x: 0, y: 2).x == 0)
            #expect(rendered.pixel(x: 5, y: 1).x == 163)
            #expect(rendered.pixel(x: 5, y: 5).x < 163)
            #expect(rendered.pixel(x: 4, y: 9).x == 79)
        }
        let diff = RuneRef.compare(scene: fixture, expected: expected, actual: rendered, channelTolerance: 2)
        #expect(diff.passed, "\(diff)")
    }

    #if canImport(Metal)
    @Test func metalSamplesNativeAndFilteredMasks() throws {
        let renderer = try MetalRenderer()
        for srgbBlend in [false, true] {
            try check(srgbBlend: srgbBlend) { try renderer.renderOffscreen($0) }
        }
    }
    #endif

    #if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
    @Test func openGLSamplesNativeAndFilteredMasks() throws {
        try withTestGLRenderer { _, render in
            for srgbBlend in [false, true] {
                try check(srgbBlend: srgbBlend, render: render)
            }
        }
    }
    #endif
}
