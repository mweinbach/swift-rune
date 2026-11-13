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
#if os(macOS)
import AppKit
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
        #expect(abs(darkGlass.w - 0.47) < 1e-3)
        let custom = MaterialMath.fallbackFill(material: .glass, fill: SIMD4<Float>(1, 0, 0, 1), dark: true, opacity: 0.5)
        #expect(abs(custom.x - 1.0) < 1e-4 && abs(custom.w - 0.5) < 1e-4)
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

    @Test("MaterialMode.fromEnv handles legacy and unsynced modes and MaterialDraw.points scales down")
    func materialModesAndPointsScaling() {
        #expect(MaterialMode.fromEnv(["RUNE_SYSTEM_MATERIAL": "legacy"]) == .legacy)
        #expect(MaterialMode.fromEnv(["RUNE_SYSTEM_MATERIAL": "unsynced"]) == .unsynced)

        let draw = MaterialDraw(
            id: 7,
            material: .glass,
            blending: .behindWindow,
            rect: MotionRect(left: 20, top: 40, right: 220, bottom: 160),
            radius: 24,
            continuous: true,
            opacity: 1.0
        )
        let logical = draw.points(scale: 2.0)
        #expect(abs(logical.rect.left - 10) < 1e-4)
        #expect(abs(logical.rect.top - 20) < 1e-4)
        #expect(abs(logical.rect.right - 110) < 1e-4)
        #expect(abs(logical.rect.bottom - 80) < 1e-4)
        #expect(abs(logical.radius - 12) < 1e-4)

        // Multi-corner radius clamp parity
        #expect(MaterialMath.clampRadius([40, 12, 8, 4], width: 60, height: 30) == 15)
        #expect(MaterialMath.clampRadius([Float](), width: 60, height: 30) == 0)
    }

    @Test("PresentSyncFlag drives presentsWithTransaction on moving, material, or live state and clears on live resize end")
    @MainActor
    func presentSyncFlagAndWatcher() {
        var sync = PresentSyncFlag()
        #expect(sync.isSynced == false)
        #expect(sync.setMaterials(true) == true)
        #expect(sync.isSynced == true)
        #expect(sync.setMaterials(false) == false)
        #expect(sync.isSynced == false)
        #expect(sync.setMoving(true) == true)
        #expect(sync.isSynced == true)
        #expect(sync.setMoving(false) == false)
        #expect(sync.isSynced == false)
        #expect(sync.setLive(true) == true)
        #expect(sync.isSynced == true)
        #expect(sync.setLive(false) == false)
        #expect(sync.isSynced == false)

        let layer = CAMetalLayer()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let watcher = MaterialPresentWatcher(window: window, metalLayer: layer)
        watcher.setLive(true)
        #expect(layer.presentsWithTransaction == true)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        #expect(watcher.flag.live == false)
        #expect(layer.presentsWithTransaction == false)
    }

    @Test("Material elements report physical rects, suppress fill, cut shadow holes, and fall back past slot cap")
    func runtimeNativeMaterialsAndFallback() throws {
        struct S {}
        let renderer = try MetalRenderer()

        // Single material at 2x scale: physical rect + suppressed fill + shadow hole cutout
        let rtSingle = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 80),
            pixelScale: 2.0,
            view: { _, _ in
                col()
                    .size(80, 80)
                    .child(
                        el()
                            .size(40, 40)
                            .absolute(x: 20, y: 20)
                            .continuousRounded(10)
                            .systemMaterial(.glass)
                            .shadow(Shadow(x: 0, y: 4, blur: 8, color: Color(r: 0, g: 0, b: 0, a: 0.9)))
                    )
            }
        )
        rtSingle.nativeMaterials = true
        rtSingle.clearColor = Color.transparent
        let rfSingle = rtSingle.renderFrame(at: 0)
        #expect(rfSingle.materials.count == 1)
        #expect(abs(rfSingle.materials[0].rect.left - 40) < 1e-3)
        #expect(abs(rfSingle.materials[0].rect.width - 80) < 1e-3)
        #expect(rfSingle.materials[0].continuous == true)

        let imgSingle = try renderer.renderOffscreen(rfSingle)
        // Native hole center (80, 80 in 160x160 2x buffer) stays transparent while outer shadow below draws dark alpha
        let centerOff = (80 * imgSingle.width + 80) * 4
        let belowOff = (128 * imgSingle.width + 80) * 4
        #expect(imgSingle.rgba[centerOff + 3] < 10)
        #expect(imgSingle.rgba[belowOff + 3] > 10)

        // Past MAX_NATIVE_MATERIALS (4): 5th material falls back to drawing tinted fill
        let rtOverflow = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 40),
            pixelScale: 1.0,
            view: { _, _ in
                var root: El<S> = row().size(120, 40)
                for _ in 0..<5 {
                    root = root.child(el().size(20, 20).systemMaterial(.hudWindow))
                }
                return root
            }
        )
        rtOverflow.nativeMaterials = true
        rtOverflow.clearColor = Color.transparent
        let rfOverflow = rtOverflow.renderFrame(at: 0)
        #expect(rfOverflow.materials.count == MAX_NATIVE_MATERIALS)
        let imgOverflow = try renderer.renderOffscreen(rfOverflow)
        // Slot 0 (x=10, y=10) is transparent hole; overflow #5 (x=90, y=10) renders fallback fill
        let holeAlpha = imgOverflow.rgba[(10 * imgOverflow.width + 10) * 4 + 3]
        let fallbackAlpha = imgOverflow.rgba[(10 * imgOverflow.width + 90) * 4 + 3]
        #expect(holeAlpha < 10)
        #expect(fallbackAlpha > 100)
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
        #expect(abs((capturedSite?.instance.rect.z ?? 0) - 40) < 1e-3) // unexpanded rect; bleed(4) is in params.z
        #expect(abs((capturedSite?.instance.params.z ?? 0) - 4) < 1e-3)
        #expect(abs((capturedSite?.scale ?? 0) - 1.0) < 1e-6)
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

    @Test("Continuous squircle corners differ from circular arcs and pill clamps radius to half short side")
    func continuousCornerAndCapsuleParity() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rtCircular = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 80),
            pixelScale: 1.0,
            view: { _, _ in
                col().size(80, 80).bg(.black).child(el().size(80, 80).rounded(24).bg(.white))
            }
        )
        let rtContinuous = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 80),
            pixelScale: 1.0,
            view: { _, _ in
                col().size(80, 80).bg(.black).child(el().size(80, 80).continuousRounded(24).bg(.white))
            }
        )

        let imgCirc = try renderer.renderOffscreen(rtCircular.renderFrame(at: 0))
        let imgCont = try renderer.renderOffscreen(rtContinuous.renderFrame(at: 0))
        // Both are solid white in center and black at extreme corner (0, 0), but differ along corner shoulder
        #expect(sampleRGBA(imgCirc, x: 40, y: 40).r > 240)
        #expect(sampleRGBA(imgCont, x: 40, y: 40).r > 240)
        #expect(sampleRGBA(imgCirc, x: 0, y: 0).r < 10)
        #expect(sampleRGBA(imgCont, x: 0, y: 0).r < 10)
        var maxDiff = 0
        for y in 0..<28 {
            for x in 0..<28 {
                maxDiff = max(maxDiff, abs(Int(sampleRGBA(imgCirc, x: x, y: y).r) - Int(sampleRGBA(imgCont, x: x, y: y).r)))
            }
        }
        #expect(maxDiff > 20)

        // Pill clamps large radius to half short side (30 / 2 = 15)
        let rtPill = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 30),
            pixelScale: 1.0,
            view: { _, _ in
                col().size(80, 30).bg(.black).child(el().size(80, 30).pill().bg(.white))
            }
        )
        let imgPill = try renderer.renderOffscreen(rtPill.renderFrame(at: 0))
        #expect(sampleRGBA(imgPill, x: 2, y: 15).r > 200)
        #expect(sampleRGBA(imgPill, x: 1, y: 1).r < 20)
    }

    @Test("BackdropBlurSchedule levels continuity and GPU parity (stripes, tint, cap, edge clamp, clip, HiDPI)")
    func backdropBlurScheduleAndGPUParity() throws {
        // Level schedule continuity & bounds
        var prevLevel = 0
        for s in stride(from: Float(0.5), through: 200.0, by: 2.5) {
            let (level, blend) = BackdropBlurSchedule.levels(sigma: s)
            #expect(level >= prevLevel && level <= BackdropBlurSchedule.mips - 1)
            #expect(blend >= 0 && blend <= 1)
            prevLevel = level
        }
        #expect(BackdropBlurSchedule.levels(sigma: 0.0).count == 0)

        let renderer = try MetalRenderer()
        struct S {}

        // 1. Stripes blend to mid-grey under blur, stay crisp outside, tinted fill tints result
        let rtStripes = Runtime<S>(
            state: S(),
            viewport: Vec2(96, 64),
            pixelScale: 1.0,
            view: { _, _ in
                var bgRow: El<S> = row().size(96, 64)
                for i in 0..<48 {
                    bgRow = bgRow.child(el().size(2, 64).bg(i % 2 == 0 ? .white : .black))
                }
                return col()
                    .size(96, 64)
                    .child(bgRow)
                    .child(
                        el()
                            .size(40, 40)
                            .absolute(x: 8, y: 12)
                            .backdropBlur(16)
                    )
                    .child(
                        el()
                            .size(32, 40)
                            .absolute(x: 56, y: 12)
                            .backdropBlur(16)
                            .bg(Color(r: 0, g: 0.4, b: 1.0, a: 0.5))
                    )
            }
        )
        let imgStripes = try renderer.renderOffscreen(rtStripes.renderFrame(at: 0))
        // Linear 0.5 grey encodes to ~188 in sRGB output and flattens stripe contrast across neighbors
        let blurCenter = sampleRGBA(imgStripes, x: 28, y: 32)
        let blurNeighbor = sampleRGBA(imgStripes, x: 26, y: 32)
        #expect(blurCenter.r > 150 && blurCenter.r < 215)
        #expect(abs(Int(blurCenter.r) - Int(blurNeighbor.r)) < 12)
        // Outside blurred rect at y=2: crisp alternating stripes preserved
        #expect(Int(sampleRGBA(imgStripes, x: 0, y: 2).r) - Int(sampleRGBA(imgStripes, x: 2, y: 2).r) > 150)
        // Tinted backdrop blur pushes blue channel above red
        let tinted = sampleRGBA(imgStripes, x: 72, y: 32)
        #expect(Int(tinted.b) > Int(tinted.r) + 30)

        // 2. Window edge flush to (0, 0) over solid white stays bright (no black edge bleed) & ancestor clip works
        let rtEdges = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 80),
            pixelScale: 2.0,
            view: { _, _ in
                col()
                    .size(80, 80)
                    .child(el().size(80, 80).bg(.white))
                    .child(el().size(40, 40).absolute(x: 0, y: 0).backdropBlur(16))
                    .child(
                        col()
                            .size(40, 40)
                            .absolute(x: 40, y: 40)
                            .clipRounded(16)
                            .child(el().size(40, 40).bg(.black).backdropBlur(16))
                    )
            }
        )
        let imgEdges = try renderer.renderOffscreen(rtEdges.renderFrame(at: 0))
        #expect(imgEdges.width == 160 && imgEdges.height == 160)
        #expect(sampleRGBA(imgEdges, x: 2, y: 2).r > 235)
        // Outside rounded clip corner at (40*2 + 2, 40*2 + 2) remains white background instead of black panel
        #expect(sampleRGBA(imgEdges, x: 82, y: 82).r > 230)

        // 3. Past MAX_BACKDROP_BLURS cap draws own fill without crashing
        let rtCap = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 40),
            pixelScale: 1.0,
            view: { _, _ in
                var root: El<S> = row().size(120, 40)
                for _ in 0..<(MAX_BACKDROP_BLURS + 2) {
                    root = root.child(el().size(20, 40).backdropBlur(10).bg(Color(r: 0, g: 1, b: 0, a: 0.8)))
                }
                return root
            }
        )
        rtCap.clearColor = Color.black
        let imgCap = try renderer.renderOffscreen(rtCap.renderFrame(at: 0))
        // Overflow element #5 at x=90 still draws green fill
        #expect(sampleRGBA(imgCap, x: 90, y: 20).g > 150)
    }

    @Test("Outer shadow cuts hole under translucent fill and adjacent KIND_TRIANGLE edges have zero seam")
    func shadowHoleCutoutAndAdjacentTriangleSeam() throws {
        let renderer = try MetalRenderer()

        // 1. Shadow hole cutout under semi-transparent fill on white background
        struct S {}
        let rtShadow = Runtime<S>(
            state: S(),
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(100, 100)
                    .child(el().size(100, 100).bg(.white))
                    .child(
                        el()
                            .size(40, 40)
                            .absolute(x: 30, y: 30)
                            .bg(Color(r: 1, g: 0, b: 0, a: 0.25))
                            .shadow(Shadow(x: 0, y: 0, blur: 10, color: Color(r: 0, g: 0, b: 0, a: 0.9)))
                    )
            }
        )
        let imgShadow = try renderer.renderOffscreen(rtShadow.renderFrame(at: 0))
        // Center at (50, 50): white * 0.75 + red * 0.25 -> clean bright pink (g >= 170), no shadow darkening underneath!
        let inner = sampleRGBA(imgShadow, x: 50, y: 50)
        // Outer shadow halo just outside box at (50, 74): darkened below pure white
        let halo = sampleRGBA(imgShadow, x: 50, y: 74)
        #expect(inner.r > 235 && inner.g >= 170)
        #expect(halo.r < 245)

        // 2. Quad polygon triangulated into two adjacent KIND_TRIANGLEs sharing diagonal (0,0)-(60,60) on blue background
        let triShape = Shape()
            .fill([Vec2(0, 0), Vec2(60, 0), Vec2(60, 60), Vec2(0, 60)], color: Color(r: 1, g: 0, b: 0, a: 1))
        let rtTri = Runtime<S>(
            state: S(),
            viewport: Vec2(60, 60),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(60, 60)
                    .child(el().size(60, 60).bg(Color(r: 0, g: 0, b: 1, a: 1)))
                    .child(el().size(60, 60).absolute(x: 0, y: 0).shape(triShape))
            }
        )
        let imgTri = try renderer.renderOffscreen(rtTri.renderFrame(at: 0))
        for d in stride(from: 10, through: 50, by: 5) {
            let diag = sampleRGBA(imgTri, x: d, y: d)
            #expect(diag.r > 240 && diag.b < 15)
        }
    }

    @Test("EffectSite bleed scissor, rounded/faded layer compositing, and sRGB blending parity")
    func effectBleedScissorAndSrgbLayerParity() throws {
        let renderer = try MetalRenderer()
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 eff_vs(uint vid [[vertex_id]]) {
            float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            return float4(pos[vid], 0.0, 1.0);
        }
        fragment float4 eff_fs() { return float4(0.0, 1.0, 0.0, 1.0); }
        """
        let lib = try renderer.device.makeLibrary(source: shaderSrc, options: nil)
        let vsFn = lib.makeFunction(name: "eff_vs")
        let fsFn = lib.makeFunction(name: "eff_fs")
        var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]

        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(100, 100)
                    .bg(.black)
                    .child(
                        col()
                            .size(60, 60)
                            .absolute(x: 20, y: 20)
                            .clipRounded(20)
                            .opacity(0.5)
                            .child(el().size(30, 30).absolute(x: 15, y: 15).effect(7).effectBleed(5))
                    )
            }
        )

        var hookFrame = rt.renderFrame(at: 0)
        hookFrame.srgbBlend = true
        let img = try renderer.renderOffscreen(hookFrame, hook: { encoder, site in
            // Verify bleed bounds are exposed and site operates inside the rounded faded layer;
            // renderer already armed encoder's scissor rect to bleed+clip bounds!
            #expect(abs(site.instance.params.z - 5) < 1e-3)
            #expect(site.inLayer == true)
            let pso: MTLRenderPipelineState
            if let cached = pipelines[site.pixelFormat] {
                pso = cached
            } else {
                let pDesc = MTLRenderPipelineDescriptor()
                pDesc.vertexFunction = vsFn
                pDesc.fragmentFunction = fsFn
                pDesc.colorAttachments[0].pixelFormat = site.pixelFormat
                pso = try! renderer.device.makeRenderPipelineState(descriptor: pDesc)
                pipelines[site.pixelFormat] = pso
            }
            encoder.setRenderPipelineState(pso)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        })
        // Outside bleed rect (x=25, y=50 is inside parent 20..80 but left of effect 35-bleed 5 = 30) must stay black due to bleed scissor!
        #expect(sampleRGBA(img, x: 25, y: 50).g < 20)
        // Layer center (50, 50) draws green attenuated by parent opacity(0.5) with srgbBlend enabled
        let mid = sampleRGBA(img, x: 50, y: 50)
        #expect(mid.g > 100 && mid.g < 220)
    }

    @Test("El.cache matches uncached output, skips re-rasterization on ancestor Live offset, invalidates on state/animation, and updates imageRevision")
    func layerCacheAndImageRevisionParity() throws {
        let renderer = try MetalRenderer()

        struct S {
            var color: Color = Color(r: 0, g: 0.8, b: 0.2, a: 1)
            var active: Bool = false
        }
        let liveShift = Live<Vec2>(.zero)

        let rtCached = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 80),
            pixelScale: 1.0,
            view: { state, _ in
                col()
                    .size(120, 80)
                    .bg(.black)
                    .child(
                        col()
                            .size(40, 40)
                            .liveOffset(liveShift.binding)
                            .child(
                                col()
                                    .size(40, 40)
                                    .cache(true)
                                    .cacheKey(0xABCD)
                                    .child(
                                        col()
                                            .size(40, 40)
                                            .rounded(8)
                                            .bg(state.color)
                                            .border(2, .white)
                                            .child(
                                                el()
                                                    .size(8, 8)
                                                    .bg(.white)
                                                    .offset(state.active ? 20 : 0, 0)
                                                    .animate(Spring(duration: 0.2, bounce: 0))
                                            )
                                    )
                            )
                    )
            }
        )

        let rtUncached = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 80),
            pixelScale: 1.0,
            view: { state, _ in
                col()
                    .size(120, 80)
                    .bg(.black)
                    .child(
                        col()
                            .size(40, 40)
                            .liveOffset(liveShift.binding)
                            .child(
                                el()
                                    .size(40, 40)
                                    .rounded(8)
                                    .bg(state.color)
                                    .border(2, .white)
                            )
                    )
            }
        )

        // 1. Frame 0 cache miss matches uncached baseline
        let imgUncached = try renderer.renderOffscreen(rtUncached.renderFrame(at: 0))
        let imgFirst = try renderer.renderOffscreen(rtCached.renderFrame(at: 0))
        #expect(sampleRGBA(imgFirst, x: 20, y: 20) == sampleRGBA(imgUncached, x: 20, y: 20))
        let statsMiss = renderer.layerStats()
        #expect(statsMiss.misses >= 1)
        #expect(statsMiss.cachedLayers >= 1)

        // 2. Move ancestor Live<Vec2> offset: hits cached texture without extra layer pass & translates pixels
        liveShift.snap(Vec2(40, 10))
        let rfHit = rtCached.renderFrame(at: 0.02)
        let imgHit = try renderer.renderOffscreen(rfHit)
        let statsHit = renderer.layerStats()
        #expect(statsHit.hits >= 1)
        #expect(statsHit.extraPasses == 0)
        #expect(sampleRGBA(imgHit, x: 60, y: 30).g > 150)
        #expect(sampleRGBA(imgHit, x: 15, y: 15).g < 20)

        // 3. State change invalidates signature -> re-rasterizes with new blue color
        rtCached.update(at: 0.04) { s, _ in s.color = Color(r: 0, g: 0.2, b: 0.9, a: 1) }
        let imgInvalidated = try renderer.renderOffscreen(rtCached.renderFrame(at: 0.04))
        #expect(sampleRGBA(imgInvalidated, x: 60, y: 30).b > 150)
        #expect(renderer.layerStats().misses > statsHit.misses)

        // 4. Child spring active -> bypasses cache (extraPasses == 0, draws live); settles -> re-caches
        rtCached.update(at: 0.05) { s, _ in s.active = true }
        _ = try renderer.renderOffscreen(rtCached.renderFrame(at: 0.08))
        #expect(renderer.layerStats().extraPasses == 0)

        _ = try renderer.renderOffscreen(rtCached.renderFrame(at: 5.0))
        let missesSettled = renderer.layerStats().misses
        _ = try renderer.renderOffscreen(rtCached.renderFrame(at: 5.05))
        #expect(renderer.layerStats().hits > statsHit.hits)
        #expect(renderer.layerStats().misses == missesSettled)

        // 5. Cache budget eviction + giveBack residentCaches
        renderer.setLayerCacheBudget(1)
        _ = try renderer.renderOffscreen(rtCached.renderFrame(at: 5.1))
        renderer.giveBack(all: true, residentCaches: true)
        #expect(renderer.layerStats().cachedLayers == 0)
        renderer.setLayerCacheBudget(64 * 1024 * 1024)

        // 6. RenderFrame.imageRevision uploads new atlas texels without recreating texture
        let redAtlas = RGBA8Atlas(width: 4, height: 4, texels: Array(repeating: 0, count: 64).enumerated().map { idx, _ in
            switch idx % 4 {
            case 0: return 255
            case 3: return 255
            default: return 0
            }
        })
        let blueAtlas = RGBA8Atlas(width: 4, height: 4, texels: Array(repeating: 0, count: 64).enumerated().map { idx, _ in
            switch idx % 4 {
            case 2, 3: return 255
            default: return 0
            }
        })
        let imgInst = RenderInstance(
            rect: SIMD4<Float>(0, 0, 20, 20),
            fill: SIMD4<Float>(1, 1, 1, 1),
            params: SIMD4<Float>(0, KIND_IMAGE, 0.5, 1),
            uv: SIMD4<Float>(0, 0, 1, 1)
        )
        let imgFrame1 = RenderFrame(width: 20, height: 20, clearColor: SIMD4<Float>(0, 0, 0, 1), images: redAtlas, imageRevision: 10, instances: [imgInst])
        let outRed = try renderer.renderOffscreen(imgFrame1)
        #expect(sampleRGBA(outRed, x: 10, y: 10).r > 200 && sampleRGBA(outRed, x: 10, y: 10).b < 20)

        let imgFrame2 = RenderFrame(width: 20, height: 20, clearColor: SIMD4<Float>(0, 0, 0, 1), images: blueAtlas, imageRevision: 11, instances: [imgInst])
        let outBlue = try renderer.renderOffscreen(imgFrame2)
        #expect(sampleRGBA(outBlue, x: 10, y: 10).b > 200 && sampleRGBA(outBlue, x: 10, y: 10).r < 20)
    }

    @Test("All MSL render shader libraries compile via ShaderLibraryCache and analytic/crisp shadows match WGSL")
    func analyticShadowAndShaderLibraryParity() throws {
        // 1. shader_tests.rs equivalent: compile and verify required entrypoints for all core MSL shaders
        let device = try #require(MTLCreateSystemDefaultDevice())
        let shaderLib = try ShaderLibraryCache.load(named: "shader", source: RenderShaders.shaderMSL, requiredFunction: "vs_springs", on: device)
        #expect(shaderLib.makeFunction(name: "vs") != nil)
        #expect(shaderLib.makeFunction(name: "fs") != nil)

        let layerBlurLib = try ShaderLibraryCache.load(named: "layer_blur", source: RenderShaders.layerBlurMSL, requiredFunction: "layer_blur_vs", on: device)
        #expect(layerBlurLib.makeFunction(name: "layer_blur_fs") != nil)

        let bBlurLib = try ShaderLibraryCache.load(named: "backdrop_blur", source: RenderShaders.backdropBlurMSL, requiredFunction: "backdrop_blur_vs", on: device)
        #expect(bBlurLib.makeFunction(name: "backdrop_blur_down") != nil)
        #expect(bBlurLib.makeFunction(name: "backdrop_blur_up") != nil)

        let bCompLib = try ShaderLibraryCache.load(named: "backdrop_composite", source: RenderShaders.backdropCompositeMSL, requiredFunction: "backdrop_composite_vs", on: device)
        #expect(bCompLib.makeFunction(name: "backdrop_composite_fs") != nil)

        // 2. Analytic rounded shadow parity (#266 item 1): large straight edge vs corner curvature & symmetric blur falloff
        let renderer = try MetalRenderer()
        struct S {}
        let rtAnalytic = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 100),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(120, 100)
                    .child(el().size(120, 100).bg(.white))
                    .child(
                        el()
                            .size(80, 60)
                            .absolute(x: 20, y: 20)
                            .rounded(14)
                            .shadow(Shadow(x: 0, y: 0, blur: 4, color: .black))
                    )
            }
        )
        let img = try renderer.renderOffscreen(rtAnalytic.renderFrame(at: 0))

        // Interior center (60, 50) hits SHADOW_INSIDE (0.99863125 -> ~5 sRGB over white)
        let center = sampleRGBA(img, x: 60, y: 50)
        #expect(center.r >= 3 && center.r <= 7 && center.g <= 7 && center.b <= 7)

        // Straight edge midpoint (60, 20) is symmetric with bottom edge (60, 79) and much darker than outer rounded corner (21, 21)
        let topMid = sampleRGBA(img, x: 60, y: 20)
        let botMid = sampleRGBA(img, x: 60, y: 79)
        let cornerPx = sampleRGBA(img, x: 21, y: 21)
        #expect(abs(Int(topMid.r) - Int(botMid.r)) <= 6)
        #expect(cornerPx.r > topMid.r + 30)

        // 3. Crisp outer shadow (blur == 0) via Runtime (#266 item 6)
        let rtCrisp = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 80),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(80, 80)
                    .child(el().size(80, 80).bg(.white))
                    .child(
                        el()
                            .size(30, 30)
                            .absolute(x: 20, y: 20)
                            .bg(Color(r: 1, g: 0, b: 0, a: 1))
                            .shadow(Shadow(x: 6, y: 6, blur: 0, color: .black))
                    )
            }
        )
        let crispImg = try renderer.renderOffscreen(rtCrisp.renderFrame(at: 0))
        // Exposed crisp shadow offset (+6, +6) at (52, 52) is pure black; untouched (58, 58) is pure white
        #expect(sampleRGBA(crispImg, x: 52, y: 52).r < 10)
        #expect(sampleRGBA(crispImg, x: 58, y: 58).r > 245)
    }
}
#endif
