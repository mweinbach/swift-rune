import Foundation
@testable import Rune
import RuneRef
import Testing

@Suite("Translucent decoded and streaming pixels")
struct PixelsAlphaRenderingTests {
    @Test("Straight RGBA and its premultiplied mip composite alike over black", arguments: [true, false])
    func equivalentPictures(srgbBlend: Bool) throws {
        let translucentPixel: [UInt8] = [175, 99, 231, 128]
        let rgba = Array(repeating: translucentPixel, count: 4).flatMap { $0 }
        let streamed = Pixels()
        streamed.set(width: 2, height: 2, rgba: rgba)
        let decoded = Pixels()
        let mips = DecodedImage.generateMipChain(width: 2, height: 2, rgba: Data(rgba))
        decoded.setDecoded(DecodedImage(id: "mip-only", width: 2, height: 2, mips: mips))

        let runtime = Runtime(state: (), viewport: Vec2(16, 8), pixelScale: 1) { _, _ in
            el().size(16, 8).bg(.black)
                .child(el().absolute(x: 0, y: 0).size(8, 8).pixels(streamed))
                .child(el().absolute(x: 8, y: 0).size(8, 8).pixels(decoded))
        }
        runtime.setSrgbBlend(srgbBlend)
        let expected = srgbBlend ? SIMD4<UInt8>(88, 50, 116, 255) : SIMD4<UInt8>(128, 71, 170, 255)
        let scene = runtime.frame(at: 0)
        func check(_ frame: Frame, renderer: String) {
            for x in [4, 12] {
                let pixel = frame.pixel(x: x, y: 4)
                for channel in 0..<4 {
                    #expect(abs(Int(pixel[channel]) - Int(expected[channel])) <= 2,
                            "\(renderer) at x=\(x) returned \(pixel), expected \(expected)")
                }
            }
        }
        check(try RuneRef.render(scene), renderer: "RuneRef")
        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        let renderer = try OffscreenGPURenderer()
        check(try renderer.renderOffscreen(scene), renderer: "GPU RefScene")
        check(try renderer.renderOffscreen(runtime.renderFrame(at: 0)), renderer: "GPU RenderFrame")
        #endif
    }

    @Test("Scaled images filter alpha inside their own atlas rectangle", arguments: [true, false])
    func scaledImageInsideAtlas(srgbBlend: Bool) throws {
        try checkAtlasCrop(from: 1, to: 3, srgbBlend: srgbBlend,
                           expectedAlpha: [255, 255, 223, 159, 96, 32, 0, 0])
    }

    @Test("A fractional fill crop samples both source texels", arguments: [4, 2])
    func centeredFillCrop(width: Int) throws {
        let pixels = Pixels()
        pixels.set(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 0, 255, 0])
        let runtime = Runtime(state: (), viewport: Vec2(Float(width), 4), pixelScale: 1) { _, _ in
            el().size(Float(width), 4).pixelsFit(pixels, .fill)
        }
        runtime.setSrgbBlend(true)
        runtime.clearColor = .transparent
        // The 4×4 viewport covers [0.5, 1.5] in the two-texel source. At 2×4 it covers [0.75, 1.25].
        let expected: [UInt8] = width == 4 ? [223, 159, 96, 32] : [159, 96]
        let scene = runtime.frame(at: 0)
        try checkRedColumns(scene: scene, production: runtime.renderFrame(at: 0), expectedAlpha: expected)
    }

    @Test("Interior, reversed and single-texel image crops preserve their sample positions")
    func directedAtlasCrops() throws {
        // Both crop edges lie inside atlas texel 2. The filter footprint still includes texel 1.
        let source = SIMD4<Float>(1, 1, 3, 2)
        try checkAtlasCrop(from: 2.125, to: 2.375, source: source, srgbBlend: true,
                           expectedAlpha: [88, 72, 56, 40])
        try checkAtlasCrop(from: 2.375, to: 2.125, source: source, srgbBlend: true,
                           expectedAlpha: [40, 56, 72, 88])
        // Here the source itself is a single red texel, with different colors on either side.
        try checkAtlasCrop(from: 2, to: 1, srgbBlend: true, expectedAlpha: [255, 255, 255, 255])
    }

    @Test("Folding opacity and packing atlas pages preserve cropped source bounds")
    func croppedSourceUnderOpacity() throws {
        let rect = SIMD4<Float>(0, 0, 4, 4)
        let source = SIMD4<Float>(0, 0, 2, 1)
        var instances = [
            RenderInstance.beginLayer(bounds: rect, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)),
            RenderInstance(rect: rect, fill: SIMD4(repeating: 1), border: source,
                           params: SIMD4(3, KIND_IMAGE, 0, 1), uv: SIMD4(0.5, 0, 1, 1)),
        ]
        var surfaces: [SurfaceDraw] = []
        var marks: [UInt32] = [0, 0]
        foldEndLayer(instances: &instances, surfaces: &surfaces, marks: &marks, start: 0, surfaceStart: 0)
        #expect(instances.count == 1)
        #expect(instances.first?.border == source)
        #expect(instances.first?.fill.w == 0.5)
        let pages = Array(repeating: RGBA8Atlas(width: 2, height: 2), count: 4)
        let frame = RenderFrame(width: 4, height: 4, imagePages: pages, instances: instances)
        let packed = try #require(frame.preparedForGL().instances.first)
        #expect(packed.uv == SIMD4<Float>(2.5, 2, 1, 1))
        #expect(packed.border == SIMD4<Float>(2, 2, 4, 3))
    }

    private func checkAtlasCrop(from left: Float, to right: Float, source: SIMD4<Float> = .zero,
                                srgbBlend: Bool, expectedAlpha: [UInt8]) throws {
        let green: [UInt8] = [0, 255, 0, 255]
        let red: [UInt8] = [255, 0, 0, 255]
        let transparentBlue: [UInt8] = [0, 0, 255, 0]
        let atlas = RGBA8Atlas(width: 4, height: 3, texels: [
            green, green, green, green,
            green, red, transparentBlue, green,
            green, green, green, green,
        ].flatMap { $0 })
        let width = expectedAlpha.count
        let bounds = SIMD4<Float>(0, 0, Float(width), 4)
        let primitive = Primitive.image(rect: bounds, uv: SIMD4(left / 4, 1.0 / 3, right / 4, 2.0 / 3),
                                        clip: bounds, sourceTexelBounds: source)
        let scene = RefScene(width: width, height: 4, srgbBlend: srgbBlend, clearColor: .zero,
                             images: atlas, primitives: [primitive])
        let instance = RenderInstance(rect: bounds, fill: SIMD4(repeating: 1), border: source,
                                      params: SIMD4(0, KIND_IMAGE, 0, 1), uv: SIMD4(left, 1, right - left, 1))
        let production = RenderFrame(width: width, height: 4, srgbBlend: srgbBlend, clearColor: .zero,
                                     images: atlas, instances: [instance])
        try checkRedColumns(scene: scene, production: production, expectedAlpha: expectedAlpha)
    }

    private func checkRedColumns(scene: RefScene, production: RenderFrame, expectedAlpha: [UInt8]) throws {
        func check(_ frame: Frame, renderer: String, premultiplied: Bool = false) {
            for y in 0..<frame.height {
                for (x, alpha) in expectedAlpha.enumerated() {
                    let red: UInt8 = premultiplied ? alpha : (alpha == 0 ? 0 : 255)
                    let expected = SIMD4<UInt8>(red, 0, 0, alpha)
                    let pixel = frame.pixel(x: x, y: y)
                    let matches = (0..<4).allSatisfy { abs(Int(pixel[$0]) - Int(expected[$0])) <= 2 }
                    #expect(matches, "\(renderer) at (\(x), \(y)) returned \(pixel), expected \(expected)")
                }
            }
        }
        check(try RuneRef.render(scene), renderer: "RuneRef")
        if production.srgbBlend {
            var target = CpuBootTarget(width: production.width, height: production.height)
            _ = try CpuBoot.paint(CpuBootScene(frame: production), into: &target, threads: 1)
            let frame = Frame(width: target.width, height: target.height, rgba: target.toRGBA8Tight())
            check(frame, renderer: "CpuBoot", premultiplied: true)
        }
        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        let renderer = try OffscreenGPURenderer()
        check(try renderer.renderOffscreen(scene), renderer: "GPU RefScene")
        check(try renderer.renderOffscreen(production), renderer: "GPU RenderFrame")
        #endif
    }
}
