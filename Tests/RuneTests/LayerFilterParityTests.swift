import Foundation
import Testing
@testable import Rune

#if canImport(Metal)
import Metal

@Suite("Layer Filter Parity (layer_filter_tests.rs)")
struct LayerFilterParityTests {
    private func solidRect(_ bounds: SIMD4<Float>, fill: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) -> RenderInstance {
        RenderInstance(
            rect: bounds,
            radii: .zero,
            fill: fill,
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
    }

    private func filtered(bounds: SIMD4<Float>, sigma: Float) -> [RenderInstance] {
        [
            .beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(blur: sigma)),
            solidRect(bounds),
            .endLayer(),
        ]
    }

    private func oracleCoverage(x: Int, start: Int, end: Int, sigma: Float) -> Float {
        let radius = Int(ceilf(3.0 * sigma))
        func weight(_ d: Int) -> Float {
            let ratio = Float(d) / sigma
            return expf(-0.5 * ratio * ratio)
        }
        var total: Float = 0
        var inside: Float = 0
        for d in -radius...radius {
            let w = weight(d)
            total += w
            let p = x + d
            if p >= start && p < end {
                inside += w
            }
        }
        return inside / total
    }

    private func drawRawLinear(
        renderer: MetalRenderer,
        instances: [RenderInstance],
        width: Int,
        height: Int,
        images: RGBA8Atlas = RGBA8Atlas(),
        imageRevision: UInt64 = 0,
        surfaces: [SurfaceDraw] = [],
        residentTracker: ResidentLayerTracker? = nil
    ) throws -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: desc),
              let cmdBuf = renderer.commandQueue.makeCommandBuffer() else {
            throw MetalRenderer.RendererError.metalUnavailable
        }
        let frame = RenderFrame(
            width: width,
            height: height,
            srgbBlend: true,
            clearColor: .zero,
            images: images,
            imageRevision: imageRevision,
            instances: instances,
            surfaces: surfaces,
            residentTracker: residentTracker
        )
        renderer.drawRange(frame: frame, into: tex, commandBuffer: cmdBuf)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            rgba[i] = bgra[i + 2]
            rgba[i + 1] = bgra[i + 1]
            rgba[i + 2] = bgra[i]
            rgba[i + 3] = bgra[i + 3]
        }
        return rgba
    }

    @Test("gaussian_pixels_support_offscreen_saturation_and_pooling")
    func gaussianOffscreenSaturationAndPooling() throws {
        let renderer = try MetalRenderer()

        // 1. Positive origin, negative origin (offscreen source), and additive saturation BEFORE blur
        let cases: [(Int, Int, Float, Bool)] = [
            (12, 10, 2.0, false),
            (-6, -4, 3.0, false),
            (12, 10, 2.0, true),
        ]
        for (left, top, sigma, additive) in cases {
            let bounds = SIMD4<Float>(Float(left), Float(top), 20, 16)
            var content = filtered(bounds: bounds, sigma: sigma)
            if additive {
                content[0].params.x = 1.0
                content.insert(solidRect(bounds), at: 2)
            }
            let out = try drawRawLinear(renderer: renderer, instances: content, width: 64, height: 48)
            #expect(renderer.layerStats().extraPasses >= 1)
            for y in 0..<48 {
                for x in 0..<64 {
                    let c = oracleCoverage(x: x, start: left, end: left + 20, sigma: sigma)
                        * oracleCoverage(x: y, start: top, end: top + 16, sigma: sigma)
                    let want = UInt8((c * 255.0).rounded())
                    let at = (y * 64 + x) * 4
                    #expect(abs(Int(out[at + 3]) - Int(want)) <= 4, "(\(x),\(y)) sigma=\(sigma) add=\(additive)")
                }
            }
        }

        // 2. Pooling across repeated/same-halo sigmas reuses targets without allocating more
        //    (Note: LayerTargetPool currently keys spare targets by exact (w, h) without 64px bucketing)
        _ = try drawRawLinear(
            renderer: renderer,
            instances: filtered(bounds: SIMD4<Float>(12, 10, 20, 16), sigma: 2.1),
            width: 64,
            height: 48
        )
        let allocs = renderer.layerStats().allocations
        for sigma: Float in [2.2, 2.3, 2.0] {
            _ = try drawRawLinear(
                renderer: renderer,
                instances: filtered(bounds: SIMD4<Float>(12, 10, 20, 16), sigma: sigma),
                width: 64,
                height: 48
            )
            #expect(renderer.layerStats().allocations == allocs)
        }

        for sigma: Float in [0.0, -1.0, .nan] {
            let out = try drawRawLinear(
                renderer: renderer,
                instances: filtered(bounds: SIMD4<Float>(12, 10, 20, 16), sigma: sigma),
                width: 64,
                height: 48
            )
            // Zero/negative/NaN blur bypasses Gaussian passes (sharp solid bounds, no blur halo).
            #expect(out[(10 * 64 + 12) * 4 + 3] == 255)
            #expect(out[(9 * 64 + 12) * 4 + 3] == 0)
        }
        renderer.giveBack(all: true, residentCaches: false)
        #expect(renderer.layerStats().targets == 0)
    }

    @Test("cached_blur_only_counts_passes_when_it_draws_the_layer")
    func cachedBlurOnlyCountsPassesOnMiss() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(32, 32),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(20, 16).bg(.white).blur(2.0).cache()
            }
        )
        _ = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        #expect(renderer.layerStats().extraPasses >= 1)

        _ = try renderer.renderOffscreen(rt.renderFrame(at: 0.016))
        #expect(renderer.layerStats().extraPasses == 0)
    }

    @Test("blur_live_springs_curves_and_zero_bypass")
    func blurLiveAndZeroBypass() {
        struct S {}
        let liveBlur = Live<Float>(0)
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(64, 48),
            pixelScale: 2.0,
            view: { _, _ in
                el().size(20, 16).bg(.white).liveBlur(liveBlur.binding)
            }
        )
        let f0 = rt.renderFrame(at: 0)
        #expect(f0.instances.count == 1)

        liveBlur.snap(2.0)
        let f1 = rt.renderFrame(at: 0.016)
        #expect(f1.instances.first?.params.y == KIND_LAYER)
        #expect(f1.instances.first?.params.z == 4.0)
        // Swift KIND_RECT stores softEdge (0.5) in params.z; layer blur does not bleed into primitive blur.
        #expect(f1.instances.count >= 2 && f1.instances[1].params.y == KIND_RECT)
        #expect(f1.instances[1].params.z == f0.instances[0].params.z)

        liveBlur.snap(0.0)
        let f2 = rt.renderFrame(at: 0.032)
        #expect(f2.instances.count == 1)

        // Later liveBlur binding replaces earlier binding
        let b0 = Live<Float>(1.0)
        let b1 = Live<Float>(2.0)
        let rtReplace = Runtime<S>(
            state: S(),
            viewport: Vec2(64, 48),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(20, 16).bg(.white).liveBlur(b0.binding).liveBlur(b1.binding)
            }
        )
        _ = rtReplace.renderFrame(at: 0)
        b0.snap(4.0)
        let rf = rtReplace.renderFrame(at: 0.016)
        #expect(rf.instances.first?.params.z == 2.0)
    }

    @Test("runtime_keeps_offscreen_blur_sources")
    func runtimeKeepsOffscreenBlurSource() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(64, 48),
            pixelScale: 1.0,
            view: { _, _ in
                col().size(64, 48).child(
                    el().size(6, 12).absolute(x: -8, y: 12).bg(.white).blur(4.0)
                )
            }
        )
        let frame = rt.renderFrame(at: 0)
        #expect(frame.instances.contains(where: { $0.params.y == KIND_RECT && $0.rect.x < 0 }))
        let out = try renderer.renderOffscreen(frame)
        #expect(out.rgba[(18 * 64) * 4 + 3] > 0, "offscreen paint contributes to visible halo")
    }

    @Test("nested_blur_and_capsule_mask_apply_to_completed_output")
    func nestedBlurAndCapsuleMask() throws {
        let renderer = try MetalRenderer()
        let clip = SIMD4<Float>(8, 8, 56, 40)
        var outer = RenderInstance.beginLayer(
            bounds: SIMD4<Float>(0, 0, 64, 48),
            clip: clip,
            spec: LayerSpec(opacity: 0.5, blur: 2.0, clipRadius: 16.0)
        )
        var all = [outer]
        all.append(contentsOf: filtered(bounds: SIMD4<Float>(0, 0, 64, 48), sigma: 2.0))
        all.append(.endLayer())
        let out1 = try drawRawLinear(renderer: renderer, instances: all, width: 64, height: 48)
        for (x, y, wantF) in [(8, 8, Float(0)), (55, 39, Float(0)), (32, 24, Float(0.5)), (32, 9, Float(0.5)), (4, 24, Float(0))] {
            let at = (y * 64 + x) * 4
            let want = UInt8((wantF * 255.0).rounded())
            #expect(abs(Int(out1[at + 3]) - Int(want)) <= 4, "(\(x),\(y))")
        }

        // Intersecting rectangular ancestor must not recenter child's rounded rect
        outer = .beginLayer(
            bounds: SIMD4<Float>(0, 0, 64, 48),
            clip: SIMD4<Float>(24, 0, 64, 48),
            spec: LayerSpec(opacity: 0.5)
        )
        all = [
            outer,
            .beginLayer(bounds: SIMD4<Float>(0, 0, 64, 48), clip: clip, spec: LayerSpec(clipRadius: 16.0)),
            solidRect(SIMD4<Float>(0, 0, 64, 48)),
            .endLayer(),
            .endLayer(),
        ]
        let out2 = try drawRawLinear(renderer: renderer, instances: all, width: 64, height: 48)
        #expect(abs(Int(out2[(8 * 64 + 24) * 4 + 3]) - 128) <= 3)
        #expect(out2[(24 * 64 + 20) * 4 + 3] == 0)
    }

    @Test("reduced_gaussian_accuracy_and_resolution_boundary_continuity")
    func reducedGaussianBoundaryContinuity() throws {
        let renderer = try MetalRenderer()
        var previous: [UInt8]? = nil
        for sigma: Float in [2.999, 3.001, 4.0, 8.0, 16.0, 64.0] {
            let out = try drawRawLinear(
                renderer: renderer,
                instances: filtered(bounds: SIMD4<Float>(24, 24, 80, 48), sigma: sigma),
                width: 128,
                height: 96
            )
            var worst = 0
            for y in 0..<96 {
                for x in 0..<128 {
                    let c = oracleCoverage(x: x, start: 24, end: 104, sigma: sigma)
                        * oracleCoverage(x: y, start: 24, end: 72, sigma: sigma)
                    let want = Int((c * 255.0).rounded())
                    let got = Int(out[(y * 128 + x) * 4 + 3])
                    worst = max(worst, abs(got - want))
                }
            }
            #expect(worst <= 5, "sigma=\(sigma) max alpha error=\(worst)")
            if sigma == 3.001, let before = previous {
                let maxDiff = zip(out, before).map { abs(Int($0) - Int($1)) }.max() ?? 0
                #expect(maxDiff <= 3, "resolution boundary must be continuous (diff=\(maxDiff))")
            }
            previous = out
        }
    }

    @Test("filtered_video_and_image_page_match_primitive_source")
    func filteredVideoAndImagePageMatchPrimitive() throws {
        let renderer = try MetalRenderer()
        let bounds = SIMD4<Float>(12, 10, 20, 16)
        let ref = try drawRawLinear(
            renderer: renderer,
            instances: filtered(bounds: bounds, sigma: 2.0),
            width: 64,
            height: 48
        )

        // 1. Image primitive in layer blur
        let whiteImg = RGBA8Atlas(width: 2, height: 2, texels: [UInt8](repeating: 255, count: 16))
        var imgInstances = filtered(bounds: bounds, sigma: 2.0)
        imgInstances[1] = RenderInstance(
            rect: bounds,
            radii: .zero,
            fill: SIMD4<Float>(1, 1, 1, 1),
            border: .zero,
            params: SIMD4<Float>(0, KIND_IMAGE, 0, 1),
            uv: SIMD4<Float>(0, 0, 1, 1),
            clip: NO_CLIP,
            fade: .zero
        )
        let imgOut = try drawRawLinear(
            renderer: renderer,
            instances: imgInstances,
            width: 64,
            height: 48,
            images: whiteImg,
            imageRevision: 1
        )
        let maxImgDiff = zip(imgOut, ref).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(maxImgDiff <= 1)

        // 2. NativeSurface (video frame) inside filtered layer
        let surface = NativeSurface()
        try surface.pushBytes(
            try ByteFrame(
                width: 1,
                height: 1,
                format: .bgra,
                color: .srgb,
                planes: [Data([255, 255, 255, 255])]
            ),
            frameId: 1
        )
        let vidInstances = [
            RenderInstance.beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(blur: 2.0)),
            RenderInstance.endLayer(),
        ]
        let vidWhite = try drawRawLinear(
            renderer: renderer,
            instances: vidInstances,
            width: 64,
            height: 48,
            surfaces: [
                SurfaceDraw(
                    surface: surface,
                    fit: .fill,
                    beforeInstance: 1,
                    rect: bounds,
                    radii: .zero,
                    clip: NO_CLIP,
                    fade: .zero,
                    opacity: 1.0
                )
            ]
        )
        let centerAt = (18 * 64 + 22) * 4
        #expect(abs(Int(vidWhite[centerAt]) - Int(ref[centerAt])) <= 3)
        #expect(abs(Int(vidWhite[centerAt + 3]) - Int(ref[centerAt + 3])) <= 3)

        // Update frame to opaque black -> reflects immediately (never stale-cached)
        try surface.pushBytes(
            try ByteFrame(
                width: 1,
                height: 1,
                format: .bgra,
                color: .srgb,
                planes: [Data([0, 0, 0, 255])]
            ),
            frameId: 2
        )
        let vidBlack = try drawRawLinear(
            renderer: renderer,
            instances: vidInstances,
            width: 64,
            height: 48,
            surfaces: [
                SurfaceDraw(
                    surface: surface,
                    fit: .fill,
                    beforeInstance: 1,
                    rect: bounds,
                    radii: .zero,
                    clip: NO_CLIP,
                    fade: .zero,
                    opacity: 1.0
                )
            ]
        )
        #expect(vidBlack[centerAt] == 0)
        #expect(abs(Int(vidBlack[centerAt + 3]) - Int(ref[centerAt + 3])) <= 3)
    }
}
#endif
