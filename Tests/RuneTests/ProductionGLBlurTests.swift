#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import Testing
import RuneRef
@testable import Rune

@MainActor
@Suite("Production GL blur passes")
struct ProductionGLBlurTests {
    private let clip = SIMD4<Float>(0, 0, 137, 95)
    private let bounds = SIMD4<Float>(29, 14, 49, 43)

    private func solid(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ color: SIMD4<Float>) -> RenderInstance {
        RenderInstance(rect: SIMD4(x, y, w, h), fill: color, clip: clip)
    }

    private func frame(sigma: Float, backdrop: Bool) -> RenderFrame {
        let orange = SIMD4<Float>(0.75, 0.25, 0.05, 1)
        var instances: [RenderInstance] = []
        if backdrop {
            for x in stride(from: 0, to: 137, by: 8) {
                instances.append(solid(Float(x), 0, 4, 95, orange))
            }
            instances.append(solid(19, 35, 95, 9, SIMD4(0.01, 0.55, 1, 1)))
            instances.append(RenderInstance(
                rect: bounds, fill: SIMD4(0, 0, 0, 1),
                params: SIMD4(sigma, KIND_BACKDROP_BLUR, 0, 0), clip: clip
            ))
        } else {
            instances.append(.beginLayer(bounds: bounds, clip: clip, spec: LayerSpec(opacity: 0.83, blur: sigma)))
            instances.append(solid(29, 14, 49, 43, orange))
            instances.append(solid(42, 39, 18, 12, SIMD4(0.02, 0.6, 0.8, 1)))
            instances.append(.endLayer())
        }
        return RenderFrame(width: 137, height: 95, srgbBlend: true,
                           clearColor: SIMD4(0.02, 0.04, 0.06, 1), instances: instances)
    }

    @Test("Gaussian layers and backdrop pyramids preserve Metal edge samples on each GL driver")
    func renderProductionBlur() throws {
        let sigmas: [Float] = [0.25, 2.5, 9.5, 26]
        // Values measured from Metal's production shaders; includes the top and
        // bottom halo outside the original layer and intersecting colored edges.
        let samples = [(35, 13), (42, 23), (69, 42), (42, 41), (57, 48), (42, 62)]
        let layerRed = [[5, 160, 160, 5, 5, 5], [70, 160, 160, 84, 50, 7],
                        [61, 121, 111, 106, 91, 37], [40, 52, 50, 53, 52, 36]]
        let backdropRed = [[191, 144, 12, 12, 144, 191], [191, 135, 19, 17, 131, 191],
                           [191, 88, 65, 65, 75, 191], [191, 89, 84, 87, 86, 191]]
        #if os(macOS)
        let metal = try MetalRenderer()
        #endif
        try withTestGLTarget { renderer, render in
            for backdrop in [false, true] {
                for (index, sigma) in sigmas.enumerated() {
                    var input = frame(sigma: sigma, backdrop: backdrop)
                    for gamma in [true, false] {
                        input.srgbBlend = gamma
                        let pixels = try render(input.width, input.height) { try renderer.draw(input) }
                        let expected = backdrop ? backdropRed[index] : layerRed[index]
                        for ((x, y), red) in zip(samples, expected) {
                            // The authored instance colors are identical in both runs. In
                            // linear mode the display resolve applies the sRGB transfer curve.
                            func displayed(_ level: Int) -> Int {
                                gamma ? level : Int((255 * RefShader.linearToSRGB(Float(level) / 255)).rounded())
                            }
                            let actual = Int(pixels.pixel(x: x, y: y).x)
                            let accepted = (displayed(red - 1) - 1)...(displayed(red + 1) + 1)
                            #expect(accepted.contains(actual), "sigma \(sigma) backdrop \(backdrop) at (\(x), \(y))")
                        }
                        #if os(macOS)
                        let reference = try metal.renderOffscreen(input)
                        let scene = RefScene(width: input.width, height: input.height)
                        let diff = RuneRef.compare(scene: scene, expected: reference, actual: pixels, channelTolerance: 2)
                        #expect(diff.passed, "sigma \(sigma) backdrop \(backdrop) srgbBlend \(gamma): \(diff)")
                        #endif
                    }
                }
            }
        }
    }

    @Test("An isolated layer can draw outside the window and blur or rotate back into view")
    func offscreenInput() throws {
        let rect = SIMD4<Float>(-17, 13, 14, 18)
        let shape = RenderInstance(rect: rect, fill: SIMD4(1, 0.2, 0, 1), clip: NO_CLIP)
        #if os(macOS)
        let metal = try MetalRenderer()
        #endif
        try withTestGLTarget { renderer, render in
            for rotated in [false, true] {
                let group = RenderInstance.beginLayer(bounds: rect, clip: NO_CLIP, spec: LayerSpec(blur: 6))
                let marker = rotated ? group.turned(angle: .pi, pivot: SIMD2(0, 32)) : group
                let input = RenderFrame(width: 64, height: 64, srgbBlend: true,
                                        clearColor: SIMD4(0, 0, 0, 1), instances: [marker, shape, .endLayer()])
                let pixels = try render(64, 64) { try renderer.draw(input) }
                let sample = rotated ? pixels.pixel(x: 9, y: 42) : pixels.pixel(x: 0, y: 21)
                #expect(sample.x > 20)
                #if os(macOS)
                let reference = try metal.renderOffscreen(input)
                let diff = RuneRef.compare(scene: RefScene(width: 64, height: 64),
                                           expected: reference, actual: pixels, channelTolerance: 2)
                #expect(diff.passed, "rotated \(rotated): \(diff)")
                #endif
            }
        }
    }
}
#endif
