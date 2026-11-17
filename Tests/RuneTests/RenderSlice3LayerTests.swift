import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import Rune

@Suite("Slice 3 Layer Parity Tests (layer_tests.rs)")
struct RenderSlice3LayerTests {
    // MARK: - Helpers (matching layer_tests.rs:4-52)

    private func rectInstance(_ bounds: SIMD4<Float>, _ color: SIMD4<Float>) -> RenderInstance {
        RenderInstance(
            rect: bounds,
            radii: .zero,
            fill: color,
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
    }

    private func groupInstances(_ bounds: SIMD4<Float>, opacity: Float, color: SIMD4<Float>) -> [RenderInstance] {
        [
            .beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: opacity)),
            rectInstance(bounds, color),
            rectInstance(SIMD4<Float>(bounds.x + bounds.z * 0.25, bounds.y, bounds.z * 0.5, bounds.w), color),
            .endLayer(),
        ]
    }

    private func srgbBytes(_ linear: SIMD4<Float>) -> [UInt8] {
        let ch: (Float, Bool) -> UInt8 = { v, isAlpha in
            let srgb: Float
            if isAlpha {
                srgb = v
            } else if v <= 0.0031308 {
                srgb = v * 12.92
            } else {
                srgb = 1.055 * powf(v, 1.0 / 2.4) - 0.055
            }
            let clamped = min(max(srgb, 0), 1)
            return UInt8((clamped * 255.0).rounded())
        }
        return [ch(linear.x, false), ch(linear.y, false), ch(linear.z, false), ch(linear.w, true)]
    }

    private func near(_ got: ArraySlice<UInt8>, _ want: [UInt8], label: String = "") {
        let arr = Array(got)
        for idx in 0..<4 {
            #expect(
                abs(Int(arr[idx]) - Int(want[idx])) <= 1,
                "\(label): \(arr) != \(want)"
            )
        }
    }

    #if canImport(Metal)
    private func drawRaw(
        renderer: MetalRenderer,
        frame: RenderFrame,
        pixelFormat: MTLPixelFormat,
        ranges: [Range<Int>]? = nil
    ) throws -> [UInt8] {
        let w = max(1, frame.width)
        let h = max(1, frame.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        desc.storageMode = .managed
        #else
        desc.storageMode = .shared
        #endif
        guard let target = renderer.device.makeTexture(descriptor: desc),
              let cb = renderer.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "RenderSlice3LayerTests", code: 1)
        }
        renderer.setFormat(pixelFormat)
        if let ranges {
            for r in ranges {
                renderer.drawRange(frame: frame, into: target, commandBuffer: cb, range: r)
            }
        } else {
            renderer.drawRange(frame: frame, into: target, commandBuffer: cb, range: nil)
        }
        #if os(macOS)
        if target.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        #endif
        cb.commit()
        cb.waitUntilCompleted()

        var raw = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(
            &raw,
            bytesPerRow: w * 4,
            from: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0
        )
        if pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb {
            for idx in stride(from: 0, to: raw.count, by: 4) {
                raw.swapAt(idx, idx + 2)
            }
        }
        return raw
    }

    #endif

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // 1. #34 (`layer_tests.rs:14`)
    @Test("raised_children_of_cached_clipped_groups_stay_visible_and_clipped")
    @MainActor
    func raisedChildrenOfCachedClippedGroupsStayVisibleAndClipped() throws {
        struct S {}
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<S>(state: S(), viewport: Vec2(32, 32), pixelScale: 1.0) { _, _ in
            el().size(32, 32).child(
                el().size(16, 16).clipRounded(8).cache().opacity(0.5).child(
                    el().size(24, 24).raise().bg(.white)
                )
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        for _ in 0..<3 {
            let rf = rt.renderFrame(at: 0.0)
            let out = try renderer.renderOffscreen(rf).rgba
            near(out[(8 * 32 + 8) * 4..<(8 * 32 + 9) * 4], [255, 255, 255, 128], label: "inside")
            near(out[(8 * 32 + 20) * 4..<(8 * 32 + 21) * 4], [0, 0, 0, 0], label: "outside-clip")
            near(out[0..<4], [0, 0, 0, 0], label: "corner")
        }
    }

    // 2. #35 (`layer_tests.rs:54`)
    @Test("isolated_layers_match_scalar_overlap_crossfade_and_nesting")
    func isolatedLayersMatchScalarOverlapCrossfadeAndNesting() throws {
        let renderer = try OffscreenGPURenderer()
        let bounds = SIMD4<Float>(4, 4, 24, 8)
        var instances = groupInstances(bounds, opacity: 0.5, color: SIMD4<Float>(1, 1, 1, 1))
        var frame = RenderFrame(width: 32, height: 16, srgbBlend: false, clearColor: .zero, instances: instances)
        var out = try renderer.renderOffscreen(frame).rgba
        for x in [6, 16, 26] {
            near(out[(8 * 32 + x) * 4..<(8 * 32 + x + 1) * 4], [255, 255, 255, 128], label: "x=\(x)")
        }
        #if canImport(Metal)
        #expect(renderer.metal.layerStats().targets == 1)
        #expect(renderer.metal.layerStats().bytes == 64 * 64 * 8, "minimum bucket")
        let allocations = renderer.metal.layerStats().allocations
        #endif

        // Two opaque states, each with internal overlap. Source-over crossfade is B(1-t) over
        // A(t): alpha = 1-t+t^2, NOT 1. Internal child overlap must never alter that oracle.
        for t in [Float(0.25), 0.5, 0.75] {
            instances = groupInstances(bounds, opacity: t, color: SIMD4<Float>(1, 0, 0, 1))
            instances.append(contentsOf: groupInstances(bounds, opacity: 1 - t, color: SIMD4<Float>(0, 0, 1, 1)))
            frame.instances = instances
            out = try renderer.renderOffscreen(frame).rgba
            let alpha = 1 - t + t * t
            let want = srgbBytes(SIMD4<Float>(t * t / alpha, 0, (1 - t) / alpha, alpha))
            for x in [6, 16, 26] {
                near(out[(8 * 32 + x) * 4..<(8 * 32 + x + 1) * 4], want, label: "crossfade t=\(t) x=\(x)")
            }
        }
        #if canImport(Metal)
        #expect(renderer.metal.layerStats().allocations == allocations + 1, "reuse targets while opacity changes")
        #endif

        instances = [.beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5))]
        instances.append(contentsOf: groupInstances(bounds, opacity: 0.5, color: SIMD4<Float>(1, 1, 1, 1)))
        instances.append(.endLayer())
        frame.instances = instances
        out = try renderer.renderOffscreen(frame).rgba
        near(out[(8 * 32 + 16) * 4..<(8 * 32 + 17) * 4], [255, 255, 255, 64], label: "nested")

        instances = groupInstances(bounds, opacity: 0.5, color: SIMD4<Float>(1, 1, 1, 1))
        for idx in 0..<3 {
            instances[idx].clip = SIMD4<Float>(8, 5, 24, 11)
        }
        frame.instances = instances
        out = try renderer.renderOffscreen(frame).rgba
        #if canImport(Metal)
        #expect(renderer.metal.layerStats().bytes == 64 * 64 * 8, "clip uses the minimum bucket")
        #expect(renderer.metal.layersPool.planner.dispositions[0].rect == SIMD4<Float>(8, 5, 16, 6))
        #endif
        near(out[(8 * 32 + 6) * 4..<(8 * 32 + 7) * 4], [0, 0, 0, 0], label: "clipped-out x=6")
        near(out[(8 * 32 + 16) * 4..<(8 * 32 + 17) * 4], [255, 255, 255, 128], label: "clipped-in x=16")

        for alpha in [Float(1.0), 0.0] {
            instances = groupInstances(bounds, opacity: alpha, color: SIMD4<Float>(1, 1, 1, 1))
            frame.instances = instances
            out = try renderer.renderOffscreen(frame).rgba
            near(out[(8 * 32 + 16) * 4..<(8 * 32 + 17) * 4], [UInt8](repeating: UInt8(alpha * 255), count: 4), label: "endpoint \(alpha)")
            #if canImport(Metal)
            #expect(renderer.metal.layerStats().targets == 0, "release on both endpoints")
            #expect(renderer.metal.layerStats().extraPasses == 0)
            #endif
        }

        #if canImport(Metal)
        // Fully opaque streams allocate no planner storage and issue only the ordinary pass.
        let ordinary = try MetalRenderer()
        let ordinaryFrame = RenderFrame(width: 32, height: 16, srgbBlend: false, clearColor: .zero, instances: [rectInstance(bounds, SIMD4<Float>(1, 1, 1, 1))])
        ordinary.prepare(frame: ordinaryFrame, viewport: (32, 16))
        _ = try drawRaw(renderer: ordinary, frame: ordinaryFrame, pixelFormat: .bgra8Unorm_srgb)
        #expect(ordinary.layerStats() == LayerStats())
        #expect(ordinary.layersPool.planner.capacities() == [0, 0, 0, 0, 0])
        #endif
    }

    // 2b. #36 (`layer_tests.rs:116`)
    @Test("leaf_dimming_keeps_container_opacity_isolated")
    @MainActor
    func leafDimmingKeepsContainerOpacityIsolated() throws {
        let alpha = Live<Float>(0.5)
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<Live<Float>>(state: alpha, viewport: Vec2(32, 16), pixelScale: 1.0) { a, _ in
            el().size(32, 16).liveOpacity(a.binding)
                .child(el().size(24, 8).absolute(x: 4, y: 4).bg(.white))
                .child(el().size(12, 8).absolute(x: 10, y: 4).bg(.white))
                .dim(0.5)
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        for (value, expectedTargets) in [(Float(0.5), 1), (Float(1.0), 0)] {
            alpha.set(value)
            let rf = rt.renderFrame(at: 0.0)
            #expect(rf.instances.filter { $0.params.y == KIND_LAYER }.count == expectedTargets)
            let out = try renderer.renderOffscreen(rf).rgba
            #if canImport(Metal)
            #expect(renderer.metal.layerStats().targets == expectedTargets)
            #endif
            near(out[(8 * 32 + 6) * 4..<(8 * 32 + 7) * 4], [255, 255, 255, UInt8((255 * 0.5 * value).rounded())], label: "alpha=\(value) x=6")
            near(out[(8 * 32 + 16) * 4..<(8 * 32 + 17) * 4], [255, 255, 255, UInt8((255 * 0.75 * value).rounded())], label: "alpha=\(value) x=16")
        }
    }

    // 3. #37 (`layer_tests.rs:138`)
    @Test("dissolve_keeps_opaque_coverage_and_isolates_each_state")
    @MainActor
    func dissolveKeepsOpaqueCoverageAndIsolatesEachState() throws {
        typealias State = (a0: Live<Float>, a1: Live<Float>)
        let a0 = Live<Float>(0.5)
        let a1 = Live<Float>(0.5)
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<State>(state: (a0, a1), viewport: Vec2(32, 16), pixelScale: 1.0) { s, _ in
            func makeState(_ alpha: Live<Float>, _ color: Color) -> El<State> {
                el().size(24, 8).absolute(x: 4, y: 4).liveOpacity(alpha.binding)
                    .child(el().size(24, 8).bg(color))
                    .child(el().size(12, 8).absolute(x: 6, y: 0).bg(color))
            }
            return el().size(32, 16).dissolve()
                .child(makeState(s.a0, Color(r: 1, g: 0, b: 0, a: 1)))
                .child(makeState(s.a1, Color(r: 0, g: 0, b: 1, a: 1)))
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false

        for t in [Float(0.5), 0.0, 0.25, 0.75, 1.0] {
            a0.set(1.0 - t)
            a1.set(t)
            let rf = rt.renderFrame(at: 0.0)
            let out = try renderer.renderOffscreen(rf).rgba
            if t == 0.0 || t == 1.0 {
                #expect(rf.instances.allSatisfy { $0.params.y != KIND_LAYER }, "no dissolve scope at rest")
                #if canImport(Metal)
                #expect(renderer.metal.layerStats().extraPasses == 0)
                #endif
            } else {
                #expect(rf.instances.contains { $0.params.y == KIND_LAYER }, "mid-fade dissolve must isolate")
                #if canImport(Metal)
                #expect(renderer.metal.layerStats().targets >= 1, "mid-fade dissolve must isolate")
                #endif
            }
            let want = srgbBytes(SIMD4<Float>(1 - t, 0, t, 1))
            for x in [6, 16, 26] {
                near(out[(8 * 32 + x) * 4..<(8 * 32 + x + 1) * 4], want, label: "t=\(t) x=\(x)")
                #expect(out[(8 * 32 + x) * 4 + 3] == 255, "opaque coverage at t=\(t)")
            }
            near(out[0..<4], [0, 0, 0, 0], label: "corner at t=\(t)")
        }

        for (rest, moving) in [(Float(0.0), Float(0.00001)), (Float(1.0), Float(0.99999))] {
            var frames: [[UInt8]] = []
            for t in [rest, moving] {
                a0.set(1.0 - t)
                a1.set(t)
                let rf = rt.renderFrame(at: 0.0)
                let out = try renderer.renderOffscreen(rf).rgba
                #if canImport(Metal)
                #expect((renderer.metal.layerStats().targets > 0) == (t == moving), "boundary rest=\(rest) t=\(t)")
                #endif
                frames.append(out)
            }
            #expect(frames[0] == frames[1], "scope boundary at \(rest)")
        }

        // Sole multi-draw state at opacity 1 still composites internally with source-over.
        let bounds = SIMD4<Float>(4, 4, 24, 8)
        var all: [RenderInstance] = [.beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: 1.0, blend: .plusLighter))]
        all.append(contentsOf: groupInstances(bounds, opacity: 1.0, color: SIMD4<Float>(0.5, 0, 0, 0.5)))
        all.append(.endLayer())
        let allFrame = RenderFrame(width: 32, height: 16, srgbBlend: false, clearColor: .zero, instances: all)
        var out = try renderer.renderOffscreen(allFrame).rgba
        near(out[(8 * 32 + 6) * 4..<(8 * 32 + 7) * 4], [255, 0, 0, 128], label: "sole-single")
        near(out[(8 * 32 + 16) * 4..<(8 * 32 + 17) * 4], [255, 0, 0, 191], label: "sole-overlap")

        // Saturate colour as well as alpha before enclosing group's fade.
        let nested: [RenderInstance] = [
            .beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)),
            .beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5, blend: .plusLighter)),
            rectInstance(bounds, SIMD4<Float>(1, 1, 1, 1)),
            rectInstance(bounds, SIMD4<Float>(1, 1, 1, 1)),
            .endLayer(),
            .endLayer(),
        ]
        let nestedFrame = RenderFrame(width: 32, height: 16, srgbBlend: false, clearColor: .zero, instances: nested)
        out = try renderer.renderOffscreen(nestedFrame).rgba
        near(out[(8 * 32 + 16) * 4..<(8 * 32 + 17) * 4], [255, 255, 255, 64], label: "nested-saturate")
    }

    // 4. #38 (`layer_tests.rs:205`)
    @Test("dissolve_samples_sequence_opacity_before_selecting_scopes")
    @MainActor
    func dissolveSamplesSequenceOpacityBeforeSelectingScopes() throws {
        struct S {}
        let outSeq = MotionSequence(frames: [
            Beat(at: 0.0),
            Beat(at: 1.0, opacity: 0.0, easing: .linear),
        ])
        let inSeq = MotionSequence(frames: [
            Beat(at: 0.0, opacity: 0.0),
            Beat(at: 1.0, easing: .linear),
        ])
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<S>(state: S(), viewport: Vec2(32, 16), pixelScale: 1.0) { _, _ in
            el().size(32, 16).dissolve()
                .child(el().size(32, 16).absolute(x: 0, y: 0).bg(.white).sequence(outSeq))
                .child(el().size(32, 16).absolute(x: 0, y: 0).bg(.white).sequence(inSeq))
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        var now = 0.0
        for (dt, active) in [(0.0, false), (0.5, true), (0.5, false)] {
            now += dt
            let rf = rt.renderFrame(at: now)
            #expect(rf.instances.contains { $0.params.y == KIND_LAYER } == active)
            let out = try renderer.renderOffscreen(rf).rgba
            for idx in stride(from: 3, to: out.count, by: 4) {
                #expect(out[idx] == 255, "complementary sequences retain opaque coverage at t=\(now)")
            }
        }
    }

    // 5. #39 (`layer_tests.rs:229`)
    @Test("dissolve_adds_direct_primitives_and_native_surfaces_then_clamps_before_opacity")
    func dissolveAddsDirectPrimitivesAndNativeSurfacesThenClampsBeforeOpacity() throws {
        let renderer = try OffscreenGPURenderer()
        let bounds = SIMD4<Float>(4, 4, 24, 8)
        let content: [RenderInstance] = [
            rectInstance(SIMD4<Float>(0, 0, 32, 16), SIMD4<Float>(0, 1, 0, 1)),
            .beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5, blend: .plusLighter)),
            rectInstance(bounds, SIMD4<Float>(1, 0, 0, 1)),
            .endLayer(),
        ]
        let surface = NativeSurface()
        let bf = try ByteFrame(width: 1, height: 1, format: .bgra, color: .srgb, planes: [Data([255, 0, 0, 255])])
        try surface.pushBytes(bf, frameId: 1)
        let draw = SurfaceDraw(
            surface: surface,
            fit: .fill,
            beforeInstance: 3,
            rect: bounds,
            radii: .zero,
            clip: NO_CLIP,
            fade: .zero,
            opacity: 1.0
        )
        let frame = RenderFrame(
            width: 32,
            height: 16,
            srgbBlend: false,
            clearColor: .zero,
            instances: content,
            surfaces: [draw]
        )
        let out = try renderer.renderOffscreen(frame).rgba
        near(out[(8 * 32 + 16) * 4..<(8 * 32 + 17) * 4], srgbBytes(SIMD4<Float>(0.5, 0.5, 0.5, 1)), label: "clamped-blend")
        near(out[0..<4], [0, 255, 0, 255], label: "background")
    }

    #endif

    #if canImport(Metal)
    // 6. #40 (`layer_tests.rs:253`)
    @Test("scale_and_fade_reuse_bucket_for_sixty_growing_frames")
    @MainActor
    func scaleAndFadeReuseBucketForSixtyGrowingFrames() throws {
        typealias State = (scale: Live<Float>, opacity: Live<Float>)
        let scale = Live<Float>(0.9)
        let opacity = Live<Float>(0.1)
        let renderer = try MetalRenderer()
        let rt = Runtime<State>(state: (scale, opacity), viewport: Vec2(256, 256), pixelScale: 1.0) { s, _ in
            el().size(256, 256).child(
                el().size(180, 180).liveScale(s.scale.binding).liveOpacity(s.opacity.binding)
                    .child(el().size(180, 180).bg(.white))
                    .child(el().size(90, 90).bg(.white))
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        var now = 0.0
        var rf = rt.renderFrame(at: now)
        renderer.prepare(frame: rf, viewport: (256, 256))
        _ = try drawRaw(renderer: renderer, frame: rf, pixelFormat: .bgra8Unorm_srgb)
        let allocations = renderer.layerStats().allocations
        let firstBounds = renderer.layersPool.planner.dispositions[0].rect
        #expect(allocations == 1)

        for frameIdx in 1...60 {
            let t = Float(frameIdx) / 60.0
            scale.set(0.9 + 0.1 * t)
            opacity.set(0.1 + 0.8 * t)
            now += 1.0 / 60.0
            rf = rt.renderFrame(at: now)
            renderer.prepare(frame: rf, viewport: (256, 256))
            let out = try drawRaw(renderer: renderer, frame: rf, pixelFormat: .bgra8Unorm_srgb)
            let expectedAlpha: Float = 0.1 + 0.8 * t
            let wantPixel = srgbBytes(SIMD4<Float>(repeating: expectedAlpha))
            near(out[(90 * 256 + 90) * 4..<(90 * 256 + 91) * 4], wantPixel, label: "frame \(frameIdx)")
            #expect(renderer.layerStats().allocations == allocations, "frame \(frameIdx)")
        }
        #expect(renderer.layersPool.planner.dispositions[0].rect.z > firstBounds.z)

        for size in [Float(20), 19, 20] {
            let smallFrame = RenderFrame(
                width: 256,
                height: 256,
                srgbBlend: false,
                clearColor: .zero,
                instances: groupInstances(SIMD4<Float>(4, 4, size, size), opacity: 0.5, color: SIMD4<Float>(1, 1, 1, 1))
            )
            renderer.prepare(frame: smallFrame, viewport: (256, 256))
            _ = try drawRaw(renderer: renderer, frame: smallFrame, pixelFormat: .bgra8Unorm_srgb)
            #expect(renderer.layerStats().bytes == 64 * 64 * 8)
            #expect(renderer.layerStats().allocations == allocations + 1)
        }
    }
    #endif

    // 7. #41 (`layer_tests.rs:291`)
    @Test("live_group_opacity_changes_scopes_without_view_or_layout_work")
    @MainActor
    func liveGroupOpacityChangesScopesWithoutViewOrLayoutWork() {
        let alpha = Live<Float>(1.0)
        let rt = Runtime<Live<Float>>(state: alpha, viewport: Vec2(32, 16), pixelScale: 1.0) { a, _ in
            el().size(32, 16).liveOpacity(a.binding)
                .child(el().size(24, 12).bg(.white))
                .child(el().size(24, 12).pin(top: 0, left: 4).bg(.white))
        }
        let rf0 = rt.renderFrame(at: 0.0)
        let commits = rt.commitCount
        let original = rf0.instances

        var t = 0.0
        alpha.set(0.5)
        t += 1.0 / 60.0
        let rf1 = rt.renderFrame(at: t)
        #expect(rt.commitCount == commits)
        #expect(rf1.instances.first?.params.y == KIND_LAYER)
        #expect(rf1.instances.last?.params.y == KIND_LAYER_END)
        #expect(rf1.instances[1].fill.w == 1.0)

        alpha.set(0.0)
        t += 1.0 / 60.0
        let rf2 = rt.renderFrame(at: t)
        #expect(rf2.instances.isEmpty)

        alpha.set(0.0009)
        t += 1.0 / 60.0
        let rf3 = rt.renderFrame(at: t)
        #expect(rf3.instances.isEmpty, "hide sub-threshold tails")

        alpha.set(1.0)
        t += 1.0 / 60.0
        let rf4 = rt.renderFrame(at: t)
        #expect(rt.commitCount == commits)
        #expect(rf4.instances == original)
    }

    // 8. #43 (`layer_tests.rs:339`)
    @Test("single_leaf_groups_keep_the_direct_path_and_springs_stay_live")
    @MainActor
    func singleLeafGroupsKeepTheDirectPathAndSpringsStayLive() {
        let alpha = Live<Float>(0.5)
        let leafRt = Runtime<Live<Float>>(state: alpha, viewport: Vec2(32, 16), pixelScale: 1.0) { a, _ in
            el().size(32, 16).liveOpacity(a.binding)
                .child(el().size(16, 16).bg(.white))
        }
        let leafFrame = leafRt.renderFrame(at: 0.0)
        #expect(leafFrame.instances.count == 1)
        #expect(leafFrame.instances[0].fill.w == 0.5)

        alpha.set(1.0)
        let groupRt = Runtime<Live<Float>>(state: alpha, viewport: Vec2(32, 16), pixelScale: 1.0) { a, _ in
            el().size(32, 16).liveOpacity(a.smooth(.default))
                .child(el().size(16, 16).bg(.white))
                .child(el().size(16, 16).pin(top: 0, left: 8).bg(.white))
        }
        _ = groupRt.renderFrame(at: 0.0)
        let commits = groupRt.commitCount
        alpha.set(0.5)
        let fA = groupRt.renderFrame(at: 1.0 / 60.0)
        let a = fA.instances[0].fill.w
        let fB = groupRt.renderFrame(at: 2.0 / 60.0)
        let b = fB.instances[0].fill.w
        #expect(fA.instances[0].params.y == KIND_LAYER)
        #expect(b < a && b > 0.5, "spring samples change the group each presentation: \(a) -> \(b)")
        #expect(groupRt.commitCount == commits)
    }

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // 9. #44 (`layer_tests.rs:369`)
    @Test("clipped_single_draw_fades_do_not_allocate_targets")
    @MainActor
    func clippedSingleDrawFadesDoNotAllocateTargets() throws {
        typealias State = (surface: NativeSurface?, mode: UInt8)
        let renderer = try OffscreenGPURenderer()
        let surface = NativeSurface()
        let bf = try ByteFrame(width: 1, height: 1, format: .bgra, color: .srgb, planes: [Data(repeating: 255, count: 4)])
        try surface.pushBytes(bf, frameId: 1)

        for mode: UInt8 in 0..<3 {
            var frames: [[UInt8]] = []
            for video in [false, true] {
                let rt = Runtime<State>(state: (video ? surface : nil, mode), viewport: Vec2(64, 48), pixelScale: 1.0) { s, _ in
                    var child: El<State> = el().size(64, 48).absolute(x: -8, y: -8)
                    if let surf = s.surface {
                        child = child.nativeSurface(surf, .fill)
                    } else {
                        child = child.bg(.white)
                    }
                    var clip: El<State> = el().size(48, 32).absolute(x: 8, y: 8)
                    switch s.mode {
                    case 0:
                        clip = clip.clipSoft(0.0)
                    case 1:
                        clip = clip.clipFade(left: 4, top: 4, right: 4, bottom: 4)
                    default:
                        clip = clip.scroll(ScrollSpec(stickBottom: false))
                    }
                    return el().child(clip.child(el().size(48, 32).opacity(0.5).child(child)))
                }
                rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                rt.srgbBlend = false
                let rf = rt.renderFrame(at: 0.0)
                #expect(rf.instances.allSatisfy { $0.params.y != KIND_LAYER })
                let out = try renderer.renderOffscreen(rf).rgba
                #if canImport(Metal)
                #expect(renderer.metal.layerStats().targets == 0, "mode=\(mode) video=\(video)")
                #endif
                #expect(out[(24 * 64 + 32) * 4 + 3] == 128)
                #expect(out[(24 * 64 + 4) * 4 + 3] == 0)
                if mode == 1 {
                    #expect(out[(24 * 64 + 8) * 4 + 3] < 32)
                }
                frames.append(out)
            }
            #expect(frames[0] == frames[1], "primitive and video inherit identical clips/fades at mode \(mode)")
        }
    }

    #endif

    // 10. #45 (`layer_tests.rs:410`)
    @Test("opacity_motion_samples_group_alpha_until_the_terminal_frame")
    @MainActor
    func opacityMotionSamplesGroupAlphaUntilTheTerminalFrame() {
        var show = true
        let rt = Runtime<Bool>(state: show, viewport: Vec2(32, 16), pixelScale: 1.0) { visible, _ in
            el().size(32, 16).opacity(visible ? 1.0 : 0.0)
                .opacityMotion(Curve.easeInOut(0.2))
                .child(el().size(16, 16).bg(.white))
                .child(el().size(16, 16).pin(top: 0, left: 8).bg(.white))
        }
        var now = 0.0
        _ = rt.renderFrame(at: now)
        show = false
        rt.state = false
        rt.invalidate()
        _ = rt.renderFrame(at: now)
        let commits = rt.commitCount

        now += 0.05
        let f1 = rt.renderFrame(at: now)
        let first = f1.instances[0].fill.w
        #expect(f1.instances[0].params.y == KIND_LAYER)

        now += 0.05
        let f2 = rt.renderFrame(at: now)
        #expect(f2.instances[0].fill.w < first)
        #expect(f2.instances[1].fill.w == 1.0)

        var lastFrame = f2
        for _ in 0..<24 {
            now += 1.0 / 60.0
            lastFrame = rt.renderFrame(at: now)
        }
        #expect(lastFrame.instances.isEmpty)
        #expect(rt.commitCount == commits)
    }

    #if canImport(Metal)
    // 11. #46 (`layer_tests.rs:433`)
    @Test("isolated_layers_preserve_image_video_spring_and_list_order")
    func isolatedLayersPreserveImageVideoSpringAndListOrder() throws {
        let renderer = try MetalRenderer()
        let bounds = SIMD4<Float>(4, 4, 24, 8)
        var content = groupInstances(bounds, opacity: 0.5, color: SIMD4<Float>(1, 0, 0, 1))

        var glyphTexels = [UInt8](repeating: 0, count: 4 * 4)
        glyphTexels[0] = 255
        let glyphs = R8Atlas(width: 4, height: 4, texels: glyphTexels)
        content.insert(
            RenderInstance(
                rect: SIMD4<Float>(9, 6, 1, 1),
                radii: .zero,
                fill: SIMD4<Float>(1, 1, 1, 1),
                border: .zero,
                params: SIMD4<Float>(0, KIND_GLYPH, 0, 1),
                uv: .zero,
                clip: NO_CLIP,
                fade: .zero
            ),
            at: 3
        )

        let px = Pixels()
        px.set(width: 1, height: 1, rgba: [0, 255, 0, 255])
        var images = ImageAtlas()
        let fullPage = Pixels()
        fullPage.set(width: 1024, height: 1024, rgba: [UInt8](repeating: 255, count: 1024 * 1024 * 4))
        _ = images.place(fullPage, drawnSize: SIMD2<Float>(1024, 1024))
        let placedOpt = images.place(px, drawnSize: SIMD2<Float>(2, 2))
        let placed = try #require(placedOpt)
        #expect(placed.page == 1)
        content.insert(
            RenderInstance(
                rect: SIMD4<Float>(15, 6, 2, 2),
                radii: .zero,
                fill: SIMD4<Float>(0, 0, 0, 1),
                border: .zero,
                params: SIMD4<Float>(Float(placed.page), KIND_IMAGE, 0, 1),
                uv: SIMD4<Float>(Float(placed.rect.x), Float(placed.rect.y), Float(placed.rect.z), Float(placed.rect.w)),
                clip: NO_CLIP,
                fade: .zero
            ),
            at: 4
        )

        let prefix = [rectInstance(SIMD4<Float>(0, 0, 2, 2), SIMD4<Float>(1, 1, 1, 1))]
        let combined = prefix + content
        let zero = GPUSpringTrack.constant(0)
        let nodes = [
            GPUSpringNode(x: zero, y: zero, opacity: .constant(1)),
            GPUSpringNode(x: .constant(1), y: zero, opacity: .constant(1)),
        ]
        var ids = [UInt32](repeating: 0, count: combined.count)
        ids[4] = 1 // glyph at absolute index 4, translated from x=9 to x=10
        renderer.withSprings(nodes: nodes, ids: ids, timeSeconds: 0.0)

        let surface = NativeSurface()
        let bf = try ByteFrame(width: 2, height: 2, format: .bgra, color: .srgb, planes: [Data([255, 0, 0, 255] + [255, 0, 0, 255] + [255, 0, 0, 255] + [255, 0, 0, 255])])
        try surface.pushBytes(bf, frameId: 1)
        let surfDraw = SurfaceDraw(
            surface: surface,
            fit: .fill,
            beforeInstance: 4,
            rect: SIMD4<Float>(22, 6, 2, 2),
            radii: .zero,
            clip: NO_CLIP,
            fade: .zero,
            opacity: 1.0
        )

        let imagePages = images.pages.map { RGBA8Atlas(width: Int($0.width), height: Int($0.height), texels: $0.data) }
        let frame = RenderFrame(
            width: 32,
            height: 16,
            srgbBlend: false,
            clearColor: .zero,
            glyphs: glyphs,
            glyphGeneration: 1,
            images: imagePages.first ?? RGBA8Atlas(),
            imagePages: imagePages,
            imageRevision: 1,
            instances: combined,
            surfaces: [surfDraw]
        )
        renderer.prepare(frame: frame, viewport: (32, 16))
        let ranges = [0..<prefix.count, prefix.count..<combined.count]
        let out = try drawRaw(renderer: renderer, frame: frame, pixelFormat: .rgba8Unorm, ranges: ranges)

        let checks: [(Int, Int, [UInt8])] = [
            (0, 0, [255, 255, 255, 255]),
            (9, 6, [128, 0, 0, 128]),
            (10, 6, [128, 128, 128, 128]),
            (15, 6, [0, 128, 0, 128]),
            (22, 6, [0, 0, 128, 128]),
        ]
        for (x, y, want) in checks {
            near(out[(y * 32 + x) * 4..<(y * 32 + x + 1) * 4], want, label: "(\(x),\(y))")
        }
    }
    #endif

    // 13. #42 (`layer_tests.rs:321`)
    @Test("isolated_exit_descendants_stay_inside_their_fading_parent")
    @MainActor
    func isolatedExitDescendantsStayInsideTheirFadingParent() {
        let rt = Runtime<Bool>(state: true, viewport: Vec2(32, 16), pixelScale: 1.0) { show, _ in
            var fading: El<Bool> = el().key("fading").size(24, 16).opacity(0.5)
                .child(el().key("kept").size(16, 16).bg(.white))
            if show {
                fading = fading.child(el().key("leaving").size(16, 16).bg(.white).transition(.opacity))
            }
            return el().size(32, 16).child(fading)
                .child(el().key("sibling").size(8, 16).pin(top: 0, left: 24).bg(Color(r: 0, g: 0, b: 1, a: 1)))
        }
        rt.srgbBlend = false
        _ = rt.renderFrame(at: 0.0)
        rt.state = false
        rt.invalidate(at: 0.0)
        let rf = rt.renderFrame(at: 0.0)
        guard let start = rf.instances.firstIndex(where: { $0.params.y == KIND_LAYER }),
              let end = rf.instances.firstIndex(where: { $0.params.y == KIND_LAYER_END }) else {
            Issue.record("expected KIND_LAYER .. KIND_LAYER_END scope")
            return
        }
        #expect(end - start == 3, "both retained descendants share the scope")
        #expect(rf.instances[end + 1].fill == SIMD4<Float>(0, 0, 1, 1), "sibling paints outside the group")
    }
}
