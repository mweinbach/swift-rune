import Testing
import Foundation
@testable import Rune
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("Render ABI & Packing Parity Tests")
struct RenderABIParityTests {
    @Test("GPU struct strides match WGSL/MSL layouts verbatim")
    func structStridesMatchWGSL() {
        #expect(MemoryLayout<RenderInstance>.stride == 128)
        #expect(MemoryLayout<RenderGlobals>.stride == 48)
        #expect(MemoryLayout<GPUSpringTrack>.stride == 48)
        #expect(MemoryLayout<GPUSpringNode>.stride == 144)
        #expect(MemoryLayout<BackdropBlurSchedule.Uniforms>.stride == 64)
    }

    @Test("IEEE-754 f16 conversion round-trips normal, negative, and clamped values")
    func f16RoundTrip() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5, 12.25, 256.0, 65504.0, 0.0009765625]
        for v in samples {
            let bits = f32ToF16Bits(v)
            let back = f16BitsToF32(bits)
            #expect(abs(back - v) <= max(1e-3, abs(v) * 1e-3))
        }
    }

    @Test("packFade and unpackFade preserve LTRB fade widths and origin clamp")
    func packAndUnpackFade() {
        let packed = packFade(
            width: SIMD4<Float>(8.0, 16.0, 24.0, 32.0),
            origin: SIMD4<Float>(8.0, 12.0, 218.0, 140.0),
            clip: SIMD4<Float>(10.0, 20.0, 200.0, 100.0)
        )
        let unpacked = unpackFade(packed)
        #expect(abs(unpacked.width.x - 8.0) < 0.05)
        #expect(abs(unpacked.width.y - 16.0) < 0.05)
        #expect(abs(unpacked.width.z - 24.0) < 0.05)
        #expect(abs(unpacked.width.w - 32.0) < 0.05)
        #expect(abs(unpacked.offset.x - 0.25) < 0.02)
        #expect(abs(unpacked.offset.y - 0.5) < 0.02)
        #expect(abs(unpacked.offset.z - 0.75) < 0.02)
        #expect(abs(unpacked.offset.w - 1.0) < 0.02)
    }

    @Test("packClipRadii encodes uniform circular, continuous, and per-corner radii")
    func packAndUnpackClipRadii() {
        let clip = SIMD4<Float>(0, 0, 160, 120)
        let uniform = packClipRadii(clip: clip, radii: SIMD4<Float>(repeating: 18))
        #expect(unpackClipRadii(uniform) == SIMD4<Float>(repeating: 18))

        let continuous = packClipRadii(clip: clip, radii: SIMD4<Float>(repeating: -12))
        let backCont = unpackClipRadii(continuous)
        #expect(backCont == SIMD4<Float>(repeating: -12))
        #expect(abs(cornerExtent(-12) - 12 * CONTINUOUS_K) < 1e-4)

        let perCorner = packClipRadii(clip: clip, radii: SIMD4<Float>(4, 12, 20, 8))
        let decoded = unpackClipRadii(perCorner)
        #expect(abs(decoded.x - 4) <= 0.5)
        #expect(abs(decoded.y - 12) <= 0.5)
        #expect(abs(decoded.z - 20) <= 0.5)
        #expect(abs(decoded.w - 8) <= 0.5)
    }

    @Test("foldEndLayer collapses empty and single unmasked scopes while keeping faded KIND_EFFECT isolated")
    func foldEndLayerBehavior() {
        var instances = [
            RenderInstance.beginLayer(bounds: SIMD4<Float>(0, 0, 100, 100), clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)),
            RenderInstance(rect: SIMD4<Float>(10, 10, 40, 40), fill: SIMD4<Float>(1, 0, 0, 1), params: SIMD4<Float>(0, KIND_RECT, 0.5, 1))
        ]
        var surfaces: [SurfaceDraw] = []
        var marks: [UInt32] = [0, 0]
        foldEndLayer(instances: &instances, surfaces: &surfaces, marks: &marks, start: 0, surfaceStart: 0)
        #expect(instances.count == 1)
        #expect(abs(instances[0].fill.x - 0.5) < 1e-5)
        #expect(abs(instances[0].fill.w - 0.5) < 1e-5)

        var effectInstances = [
            RenderInstance.beginLayer(bounds: SIMD4<Float>(0, 0, 100, 100), clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)),
            RenderInstance(rect: SIMD4<Float>(0, 0, 100, 100), params: SIMD4<Float>(0, KIND_EFFECT, 0, 1))
        ]
        var effectMarks: [UInt32] = [0, 7]
        foldEndLayer(instances: &effectInstances, surfaces: &surfaces, marks: &effectMarks, start: 0, surfaceStart: 0)
        #expect(effectInstances.count == 3)
        #expect(effectInstances.last?.params.y == KIND_LAYER_END)
    }
}

@Suite("System Material & Slot Assignment Parity Tests")
struct SystemMaterialParityTests {
    @Test("clampRadius, fallbackFill, and MaterialMode.fromEnv match upstream")
    func materialMathParity() {
        #expect(MaterialMath.clampRadius(40, width: 50, height: 30) == 15)
        #expect(MaterialMath.clampRadius(-5, width: 50, height: 30) == 0)
        #expect(MaterialMode.fromEnv(["RUNE_SYSTEM_MATERIAL": "fallback"]) == .fallback)
        #expect(MaterialMode.fromEnv(["RUNE_SYSTEM_MATERIAL": "off"]) == .fallback)
        #expect(MaterialMode.fromEnv(["RUNE_SYSTEM_MATERIAL": "native"]) == .native)
        #expect(MaterialMode.fromEnv([:]) == .auto)

        let darkGlass = MaterialMath.fallbackFill(material: .glass, dark: true, opacity: 0.5)
        let lightGlass = MaterialMath.fallbackFill(material: .glass, dark: false, opacity: 0.5)
        #expect(darkGlass.x < lightGlass.x)
        #expect(abs(darkGlass.w - 0.34) < 1e-3)
    }

    @Test("assignSlots caps native slots at 4, preserves IDs, and sends overflow to fallback")
    func assignSlotsCapAndStability() {
        let draws: [MaterialDraw] = (1...6).map { (i: Int) -> MaterialDraw in
            let left = Float(i * 10)
            let right = left + Float(40)
            return MaterialDraw(
                id: UInt64(i),
                material: .hudWindow,
                blending: .behindWindow,
                rect: MotionRect(left: left, top: 10, right: right, bottom: 50),
                radius: 30,
                continuous: true,
                opacity: 1.0
            )
        }
        let first = MaterialMath.assignSlots(draws, mode: .auto, liveResize: true, previousIds: [])
        #expect(first.nativeSlots.count == MAX_NATIVE_MATERIALS)
        #expect(first.fallbackDraws.count == 2)
        #expect(first.presentFlag == .synchronized)
        #expect(first.nativeSlots[0].clampedRadius == 20)

        let reordered = [draws[3], draws[1], draws[0], draws[4]]
        let second = MaterialMath.assignSlots(reordered, mode: .auto, liveResize: false, previousIds: [1, 2, 3, 4])
        #expect(second.nativeSlots.first { $0.draw.id == 4 }?.slotIndex == 3)
        #expect(second.nativeSlots.first { $0.draw.id == 2 }?.slotIndex == 1)
        #expect(second.presentFlag == .immediate)
    }

    #if os(macOS)
    @Test("RuneMaterialHost applies pooled slots without intercepting hits")
    @MainActor
    func macosMaterialHostBehavior() {
        let host = RuneMaterialHost(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        #expect(host.isFlipped == true)
        #expect(host.hitTest(NSPoint(x: 50, y: 50)) == nil)

        let draw = MaterialDraw(
            id: 42,
            material: .glass,
            blending: .behindWindow,
            rect: MotionRect(left: 10, top: 10, right: 110, bottom: 70),
            radius: 12,
            continuous: true,
            opacity: 0.9
        )
        let assignment = host.apply([draw], mode: .native)
        #expect(assignment.nativeSlots.count == 1)
        #expect(assignment.fallbackDraws.isEmpty)
        host.hideAll()
    }
    #endif
}

@Suite("GlyphAtlas Lazy Allocation (#830) Tests")
struct GlyphAtlasLazyAllocationTests {
    @Test("GlyphAtlas starts unallocated until first glyph or icon blit")
    func lazyFirstPage() {
        let atlas = GlyphAtlas(width: 512, height: 512)
        #expect(atlas.isAllocated == false)
        #expect(atlas.backingByteCount == 0)
        #expect(atlas.atlas.width == 1 && atlas.atlas.height == 1)

        let checkIcon = SVGIcon(viewBox: 24, paths: ["M 4 12 L 10 18 L 20 6"], strokeWidth: 2)
        _ = atlas.rasterizeIcon(checkIcon, pixelSize: 16)
        #expect(atlas.isAllocated == true)
        #expect(atlas.backingByteCount == 512 * 512)
        #expect(atlas.atlas.width == 512 && atlas.atlas.height == 512)
    }
}

#if canImport(Metal) && canImport(QuartzCore)
@Suite("GPU RenderFrame Parity Tests (Clips, Gradients, Effects, Blur, Springs, Cache)")
struct RenderGPUAndShaderParityTests {
    private func sampleRGBA(_ frame: Frame, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cx = max(0, min(frame.width - 1, x))
        let cy = max(0, min(frame.height - 1, y))
        let off = (cy * frame.width + cx) * 4
        return (frame.rgba[off], frame.rgba[off + 1], frame.rgba[off + 2], frame.rgba[off + 3])
    }

    @Test("Rounded clip, feathered fade clip, and cutoutCircle mask pixels accurately on Metal GPU")
    func gpuRoundedFeatheredAndCutoutClips() throws {
        let renderer = try MetalRenderer()

        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 120),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(120, 120)
                    .bg(.transparent)
                    .child(
                        col()
                            .size(80, 80)
                            .clipRounded(24)
                            .cutoutCircle(cx: 40, cy: 40, radius: 12, feather: 2)
                            .child(el().size(80, 80).bg(Color(r: 1, g: 0, b: 0, a: 1)))
                    )
                    .child(
                        col()
                            .size(40, 20)
                            .clipFade(left: 16)
                            .child(el().size(40, 20).bg(Color(r: 0, g: 1, b: 0, a: 1)))
                    )
            }
        )
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 1)
        let rf = rt.renderFrame(at: 0)
        let frame = try renderer.renderOffscreen(rf)

        // Outer corner at (2, 2) must be clipped out by clipRounded(24) -> black clear color
        let cornerPx = sampleRGBA(frame, x: 2, y: 2)
        #expect(cornerPx.r < 10)
        // Center of circular cutout (40, 40) must be punched out -> black clear color
        let holePx = sampleRGBA(frame, x: 40, y: 40)
        #expect(holePx.r < 10)
        // Ring inside box at (20, 40) must be red
        let ringPx = sampleRGBA(frame, x: 20, y: 40)
        #expect(ringPx.r > 200)
        // Feathered row at y = 90: left edge (x = 1) fainter green than interior right (x = 30)
        let fadeEdge = sampleRGBA(frame, x: 1, y: 90)
        let fadeFull = sampleRGBA(frame, x: 30, y: 90)
        #expect(fadeEdge.g < fadeFull.g)
        #expect(fadeFull.g > 200)
    }

    @Test("Multi-stop linear & positioned radial gradients and borderGradient render cleanly on GPU")
    func gpuGradientsAndBorderGradient() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 80),
            pixelScale: 1.0,
            view: { _, _ in
                row()
                    .size(120, 80)
                    .child(
                        el()
                            .size(40, 80)
                            .linearGradient(angle: 0, stops: [
                                GradientStop(Color(r: 1, g: 0, b: 0, a: 1), at: 0),
                                GradientStop(Color(r: 0, g: 1, b: 0, a: 1), at: 0.5),
                                GradientStop(Color(r: 0, g: 0, b: 1, a: 1), at: 1),
                            ])
                    )
                    .child(
                        el()
                            .size(40, 80)
                            .radialGradient(center: Vec2(0.5, 0.5), radius: .closestSide, stops: [
                                GradientStop(Color(r: 1, g: 1, b: 1, a: 1), at: 0),
                                GradientStop(Color(r: 0, g: 0, b: 0, a: 1), at: 1),
                            ])
                    )
                    .child(
                        el()
                            .size(40, 80)
                            .bg(Color(r: 0, g: 0, b: 0, a: 1))
                            .borderGradient(width: 4, top: Color(r: 1, g: 0, b: 0, a: 1), bottom: Color(r: 0, g: 0, b: 1, a: 1))
                    )
            }
        )
        let frame = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        // Multi-stop horizontal linear: red left (x=3), green mid (x=20), blue right (x=37)
        #expect(sampleRGBA(frame, x: 3, y: 40).r > 180)
        #expect(sampleRGBA(frame, x: 20, y: 40).g > 180)
        #expect(sampleRGBA(frame, x: 37, y: 40).b > 180)
        // Positioned radial: white center (x=60, y=40), dark corner (x=42, y=5)
        let radCenter = sampleRGBA(frame, x: 60, y: 40)
        let radCorner = sampleRGBA(frame, x: 42, y: 5)
        #expect(radCenter.r > 200 && radCenter.g > 200 && radCenter.b > 200)
        #expect(radCorner.r < 40)
        // Border gradient: top border pixel (x=100, y=1) red, bottom border pixel (x=100, y=78) blue
        #expect(sampleRGBA(frame, x: 100, y: 1).r > 180)
        #expect(sampleRGBA(frame, x: 100, y: 78).b > 180)
    }

    @Test("Effect slots deliver EffectSite data, bleed bounds, inLayer, and backdrop snapshots")
    func effectSlotsAndBackdropHook() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(100, 100)
                    .child(el().size(100, 100).bg(Color(r: 0.2, g: 0.6, b: 0.9, a: 1)))
                    .child(
                        col()
                            .size(60, 60)
                            .absolute(x: 20, y: 20)
                            .clipRounded(4)
                            .child(
                                el()
                                    .size(40, 40)
                                    .effect(0xCAFE_BABE)
                                    .effectBleed(4)
                                    .effectBackdrop(true)
                                    .effectData(SIMD4<Float>(1, 2, 3, 4))
                            )
                    )
            }
        )
        var sawBackdropPhase = false
        var sawDrawPhase = false
        var capturedSite: EffectSite?
        _ = try renderer.renderOffscreen(rt.renderFrame(at: 0), backdropHook: { phase, site in
            switch phase {
            case .backdrop:
                sawBackdropPhase = true
                #expect(site.backdrop != nil)
            case .draw:
                sawDrawPhase = true
            }
            capturedSite = site
        })
        #expect(sawBackdropPhase == true)
        #expect(sawDrawPhase == true)
        #expect(capturedSite?.mark == 0xCAFE_BABE)
        #expect(capturedSite?.data == SIMD4<Float>(1, 2, 3, 4))
        #expect(capturedSite?.inLayer == true)
        #expect(abs((capturedSite?.instance.rect.z ?? 0) - 48) < 1e-3) // 40 + 2 * bleed(4)
    }

    @Test("Backdrop blur, Gaussian layer blur, and LayersPool LRU + #819 giveBack operate cleanly")
    func blurAndLayersPoolGiveBack() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 80),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(80, 80)
                    .child(el().size(40, 80).bg(Color(r: 1, g: 0, b: 0, a: 1)))
                    .child(el().size(40, 80).absolute(x: 40, y: 0).bg(Color(r: 0, g: 0, b: 1, a: 1)))
                    .child(el().size(40, 40).absolute(x: 20, y: 20).rounded(8).backdropBlur(12))
            }
        )
        let blurred = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        // Seam center at (40, 40) under backdrop blur must blend red & blue into purple (>20 both R and B)
        let seam = sampleRGBA(blurred, x: 40, y: 40)
        #expect(seam.r > 20 && seam.b > 20)

        let statsBefore = renderer.layerStats()
        #expect(statsBefore.allocations >= 0)
        renderer.giveBack(all: true, residentCaches: false)
        let statsAfter = renderer.layerStats()
        #expect(statsAfter.targets == 0)
        #expect(statsAfter.bytes == 0)

        // Direct LayersPool LRU eviction test
        let pool = LayersPool(cacheBudgetBytes: 64 * 64 * 8 * 2) // room for 2 targets
        for k: UInt64 in 1...4 {
            pool.beginFrame()
            if let t = pool.acquireRetainedTarget(device: renderer.device, width: 64, height: 64) {
                pool.storeRetained(key: k, texture: t)
            }
            pool.endFrame()
        }
        let poolStats = pool.stats()
        #expect(poolStats.cachedLayers <= 2)
        #expect(poolStats.evictions >= 2)
    }

    @Test("GPUSpringBindings + vs_springs animates vertex offset and settles cleanly")
    func gpuSpringsAnimation() throws {
        let renderer = try MetalRenderer()
        let frame = RenderFrame(
            width: 80,
            height: 40,
            clearColor: SIMD4<Float>(0, 0, 0, 1),
            instances: [
                RenderInstance(
                    rect: SIMD4<Float>(10, 10, 16, 16),
                    fill: SIMD4<Float>(1, 1, 1, 1),
                    params: SIMD4<Float>(0, KIND_RECT, 0.5, 1)
                )
            ]
        )
        let trackX = GPUSpringTrack(spring: Spring(duration: 0.2, bounce: 0.0), initial: 0, velocity: 0, goal: 40, startSeconds: 0.0)
        renderer.withSprings(nodes: [GPUSpringNode(x: trackX, y: .constant(0), opacity: .constant(1))], ids: [0], timeSeconds: 0.0)
        #expect(renderer.springsAnimating(at: 0.0) == true)
        let startImg = try renderer.renderOffscreen(frame)
        #expect(sampleRGBA(startImg, x: 18, y: 18).r > 200)
        #expect(sampleRGBA(startImg, x: 58, y: 18).r < 20)

        renderer.setSpringTime(5.0)
        #expect(renderer.springsAnimating(at: 5.0) == false)
        let endImg = try renderer.renderOffscreen(frame)
        #expect(sampleRGBA(endImg, x: 18, y: 18).r < 20)
        #expect(sampleRGBA(endImg, x: 58, y: 18).r > 200)
        renderer.clearSprings()
    }

    @Test("Shape drawn/trimmed, strokeWidth, and LineCap.round render accurately via RenderFrame")
    func shapeTrimAndLineCapRenderFrame() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let lineShape = Shape().strokeWith([Vec2(10, 20), Vec2(70, 20)], closed: false, width: 6, cap: .round, color: Color(r: 1, g: 1, b: 0, a: 1))
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 40),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(80, 40).shape(lineShape.drawn(0.5))
            }
        )
        let img = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        // Drawn half covers [10..40]; round cap at x=10 extends slightly left (x=8 covered)
        #expect(sampleRGBA(img, x: 8, y: 20).r > 150)
        #expect(sampleRGBA(img, x: 25, y: 20).r > 200)
        #expect(sampleRGBA(img, x: 60, y: 20).r < 20)
    }
}
#endif
