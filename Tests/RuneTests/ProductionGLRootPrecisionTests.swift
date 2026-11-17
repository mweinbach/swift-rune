#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import RuneRef
import Testing
@testable import Rune

@MainActor
@Suite("Production GL root color storage")
struct ProductionGLRootPrecisionTests {
    private let color = SIMD4<Float>(0.1, 0.3, 0.8, 1)

    private func rectangle(_ fill: SIMD4<Float>) -> RenderInstance {
        RenderInstance(rect: SIMD4(-4, -4, 16, 16), fill: fill, params: SIMD4(0, KIND_RECT, 0, 1), clip: NO_CLIP)
    }

    @Test("Clears and draws use premultiplied byte storage before straight RGBA readback")
    func lowAlpha() throws {
        #if os(macOS)
        let metal = try MetalRenderer()
        #endif
        let blur = RenderInstance(rect: SIMD4(0, 0, 3, 3), fill: SIMD4(0, 0, 0, 1),
                                  params: SIMD4(1, KIND_BACKDROP_BLUR, 0, 0), clip: NO_CLIP)
        try withTestGLTarget { renderer, capture in
            for gamma in [true, false] {
                for alpha in [Float(0.01), 0.0004] {
                    let fill = color * alpha
                    let expected: SIMD4<UInt8> = alpha == 0.01
                        ? (gamma ? SIMD4(0, 85, 170, 3) : SIMD4(79, 139, 215, 3))
                        : (gamma ? .zero : SIMD4(0, 0, 1, 0))
                    for primitives in [[], [rectangle(fill)], [blur, rectangle(fill)]] {
                        let frame = RenderFrame(width: 8, height: 8, srgbBlend: gamma,
                                                clearColor: primitives.isEmpty ? fill : .zero, instances: primitives)
                        let image = try capture(8, 8) { try renderer.draw(frame) }
                        #expect(image.pixel(x: 5, y: 5) == expected)
                        #if os(macOS)
                        #expect(image.rgba == (try metal.renderOffscreen(frame)).rgba)
                        #endif
                    }
                }
            }
        }
    }

    #if os(macOS)
    @Test("Overlapping translucent fragments blend against the previous stored root pixel")
    func translucentOverdraw() throws {
        let metal = try MetalRenderer()
        try withTestGLTarget { renderer, capture in
            for alpha in [Float(0.01), 0.02, 0.05, 0.2] {
                let fill = color * alpha
                for gamma in [false, true] {
                    let frame = RenderFrame(width: 8, height: 8, srgbBlend: gamma, clearColor: fill,
                                            instances: Array(repeating: rectangle(fill), count: 3))
                    let image = try capture(8, 8) { try renderer.draw(frame) }
                    let reference = try metal.renderOffscreen(frame)
                    let errors = zip(image.rgba, reference.rgba).map { abs(Int($0) - Int($1)) }
                    #expect(errors.allSatisfy { $0 <= 1 }, "alpha \(alpha), byte blending \(gamma)")
                }
            }
        }
    }
    #endif
}
#endif
