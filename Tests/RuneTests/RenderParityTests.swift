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
        // `a_window_move_never_turns_off_transactions_materials_need` (`system_material/tests.rs:146`)
        var sync = PresentSyncFlag()
        #expect(sync.isSynced == false)
        #expect(sync.setMaterials(true) == true)
        #expect(sync.setMoving(true) == nil)
        #expect(sync.setMoving(false) == nil)
        #expect(sync.setMaterials(false) == false)
        #expect(sync.setMoving(true) == true)
        #expect(sync.setMaterials(true) == nil)
        #expect(sync.setMaterials(false) == nil)
        #expect(sync.setMoving(false) == false)
        #expect(sync.setMoving(false) == nil)

        // `a_live_resize_keeps_transactions_on_until_it_ends` (`system_material/tests.rs:163`)
        var resizeSync = PresentSyncFlag()
        #expect(resizeSync.setLive(true) == true)
        #expect(resizeSync.setMoving(false) == nil)
        #expect(resizeSync.setMaterials(false) == nil)
        #expect(resizeSync.setLive(true) == nil)
        #expect(resizeSync.setLive(false) == false)
        #expect(resizeSync.setMaterials(true) == true)
        #expect(resizeSync.setLive(true) == nil)
        #expect(resizeSync.setLive(false) == nil)

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
        watcher.setMaterials(true)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        #expect(watcher.flag.live == false)
        #expect(layer.presentsWithTransaction == true)
        watcher.setMaterials(false)
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

    @Test("srgb_blend_frost_over_a_native_material_reads_as_core_animation (system_material/tests.rs:280)")
    func srgbBlendFrostOverNativeMaterial() throws {
        struct S { var frost: Float = 1.0 }
        let renderer = try MetalRenderer()
        let readFrost: (Bool, Float, Color) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = { srgb, frostVal, clearCol in
            let rt = Runtime<S>(
                state: S(frost: frostVal),
                viewport: Vec2(200, 120),
                pixelScale: 2.0,
                view: { s, _ in
                    col()
                        .size(200, 120)
                        .child(
                            col()
                                .absolute(x: 30, y: 20)
                                .size(120, 60)
                                .continuousRounded(18)
                                .systemMaterial(.glass)
                                .child(
                                    el()
                                        .size(120, 60)
                                        .bg(Color.white.alpha(0.62 * s.frost))
                                )
                        )
                }
            )
            rt.nativeMaterials = true
            rt.srgbBlend = srgb
            rt.clearColor = clearCol
            let frame = rt.renderFrame(at: 0)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: srgb ? .bgra8Unorm : .bgra8Unorm_srgb,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            let tex = try #require(renderer.device.makeTexture(descriptor: desc))
            let cb = try #require(renderer.commandQueue.makeCommandBuffer())
            renderer.drawRange(frame: frame, into: tex, commandBuffer: cb, range: 0..<frame.instances.count)
            cb.commit()
            cb.waitUntilCompleted()
            var bgra = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
            tex.getBytes(&bgra, bytesPerRow: frame.width * 4, from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0)
            let off = (100 * frame.width + 180) * 4
            return (bgra[off + 2], bgra[off + 1], bgra[off + 0], bgra[off + 3])
        }

        let black = Color(r: 0, g: 0, b: 0, a: 1)
        let linBlack = try readFrost(false, 1.0, black)
        let srgbBlack = try readFrost(true, 1.0, black)
        let srgbClear = try readFrost(true, 1.0, .transparent)
        let srgbZero = try readFrost(true, 0.0, .transparent)
        #expect(abs(Int(linBlack.r) - 206) <= 1 && linBlack.a == 255)
        #expect(abs(Int(srgbBlack.r) - 158) <= 1 && srgbBlack.a == 255)
        #expect(abs(Int(srgbClear.r) - 158) <= 1 && abs(Int(srgbClear.a) - 158) <= 1)
        #expect(srgbZero == (0, 0, 0, 0))
    }
    #endif
}

@Suite("GlyphAtlas Lazy Allocation (#830) Tests")
struct GlyphAtlasLazyAllocationTests {
    @Test("GlyphAtlas starts unallocated until first glyph or icon blit")
    func lazyFirstPage() {
        let atlas = GlyphAtlas(width: 512, height: 512)
        #expect(atlas.hasAllocatedBacking == false)
        #expect(atlas.allocatedBackingBytes == 0)
        #expect(atlas.atlas.width == 1 && atlas.atlas.height == 1)

        let checkIcon = SVGIcon(viewBox: 24, paths: ["M 4 12 L 10 18 L 20 6"], strokeWidth: 2)
        _ = atlas.rasterizeIcon(checkIcon, pixelSize: 16)
        #expect(atlas.hasAllocatedBacking == true)
        #expect(atlas.allocatedBackingBytes == 512 * 512)
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
                            .linearGradient(angle: .pi * 0.5, stops: [
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

    @Test("border_gradient ring instance encoding, replacement semantics, and AA parity (border_gradient.rs:55,67,108)")
    func borderGradientInstanceAndPixelsParity() throws {
        enum Mode { case gradient, borderThenGradient, gradientThenBorder, rimGradient, rimBorder }
        let top = Color(r: 1, g: 0, b: 0, a: 1)
        let bottom = Color(r: 0, g: 0, b: 1, a: 1)
        let rim = Color(r: 1, g: 1, b: 1, a: 0.15)
        let dark = Color(r: 0.1, g: 0.1, b: 0.12, a: 1)

        func makeRt(_ mode: Mode) -> Runtime<Mode> {
            Runtime<Mode>(
                state: mode,
                viewport: Vec2(68, 22),
                pixelScale: 2.0,
                view: { m, _ in
                    let cap: El<Mode> = el().absolute(x: 4, y: 4).size(60, 14).rounded(7)
                    let styled: El<Mode>
                    switch m {
                    case .gradient: styled = cap.borderGradient(width: 0.5, top: top, bottom: bottom)
                    case .borderThenGradient: styled = cap.border(1.0, rim).borderGradient(width: 0.5, top: top, bottom: bottom)
                    case .gradientThenBorder: styled = cap.borderGradient(width: 0.5, top: top, bottom: bottom).border(1.0, rim)
                    case .rimGradient: styled = cap.bg(dark).borderGradient(width: 0.5, top: rim, bottom: rim)
                    case .rimBorder: styled = cap.bg(dark).border(0.5, rim)
                    }
                    return el().size(68, 22).child(styled)
                }
            )
        }
        func ring(_ rt: Runtime<Mode>) -> RenderInstance {
            rt.renderFrame(at: 0).instances.first { $0.params.x > 0 }!
        }

        let gInst = ring(makeRt(.gradient))
        #expect(gInst.params.y == KIND_GRADIENT)
        #expect(gInst.params.x == 1.0)
        #expect(gInst.rect == SIMD4<Float>(8, 8, 120, 28))
        #expect(gInst.radii == SIMD4<Float>(repeating: 14))
        #expect(gInst.fill == .zero)
        #expect(abs(gInst.border.x - 1) < 1e-5 && abs(gInst.border.y) < 1e-5 && abs(gInst.border.z) < 1e-5 && abs(gInst.border.w - 1) < 1e-5)
        #expect(abs(gInst.uv.x) < 1e-5 && abs(gInst.uv.y) < 1e-5 && abs(gInst.uv.z - 1) < 1e-5 && abs(gInst.uv.w - 1) < 1e-5)

        let bgInst = ring(makeRt(.borderThenGradient))
        #expect(bgInst.params.y == KIND_GRADIENT && bgInst.params.x == 1.0)
        let gbInst = ring(makeRt(.gradientThenBorder))
        #expect(gbInst.params.y == KIND_RECT && gbInst.params.x == 2.0 && gbInst.uv == .zero)

        let renderer = try MetalRenderer()
        let outG = try renderer.renderOffscreen({
            let rt = makeRt(.gradient)
            rt.clearColor = .transparent
            return rt.renderFrame(at: 0)
        }())
        let topPx = sampleRGBA(outG, x: 68, y: 8)
        let botPx = sampleRGBA(outG, x: 68, y: 35)
        let midPx = sampleRGBA(outG, x: 68, y: 20)
        #expect(topPx.r > 240 && topPx.b < 70 && topPx.a > 250)
        #expect(botPx.b > 240 && botPx.r < 70 && botPx.a > 250)
        #expect(midPx.a == 0)

        let fRimGrad = makeRt(.rimGradient).renderFrame(at: 0)
        let fRimBord = makeRt(.rimBorder).renderFrame(at: 0)
        let imgA = try renderer.renderOffscreen(fRimGrad)
        let imgB = try renderer.renderOffscreen(fRimBord)
        var maxDiff = 0
        for i in 0..<imgA.rgba.count {
            maxDiff = max(maxDiff, abs(Int(imgA.rgba[i]) - Int(imgB.rgba[i])))
        }
        #expect(maxDiff <= 1)
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

    @Test("GPUSpringBindings + vs_springs animates vertex offset and arbitrary retarget settle bounds hold for the tail")
    func gpuSpringsAnimation() throws {
        #expect(MemoryLayout<GPUSpringTrack>.stride == 48)
        #expect(MemoryLayout<GPUSpringNode>.stride == 144)
        #expect(GPUSpringTrack.constant(1.0).settleAt() == 0.0)

        // `arbitrary_retarget_settle_bounds_hold_for_the_tail` (`gpu/springs.rs:135`)
        for bounce: Float in [-0.9, -0.2, 0.0, 0.16, 0.8] {
            let spring = Spring(duration: 0.4, bounce: bounce)
            for velocity: Float in [-800.0, 0.0, 900.0] {
                let (from, vel) = spring.sample(from: -120.0, velocity: velocity, target: 40.0, at: 0.12)
                let duration = spring.settlingDuration(from: from, velocity: vel, target: -30.0, epsilon: 0.001)
                for i in 0..<200 {
                    let (x, v) = spring.sample(from: from, velocity: vel, target: -30.0, at: duration + Float(i) / 120.0)
                    #expect(abs(x + 30.0) <= 0.00101, "bounce \(bounce): x=\(x)")
                    #expect(abs(v) <= 0.01001, "bounce \(bounce): v=\(v)")
                }
            }
        }

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

    @Test("Continuous squircle corners follow Apple's cubic curve in fills and clips and pill clamps radius")
    func continuousCornerAndCapsuleParity() throws {
        let renderer = try MetalRenderer()

        // Apple's continuous corner for r = 1: three cubics from (0, K) to (K, 0) (`continuous_corner_tests.rs:6-40`)
        let curve: [SIMD2<Float>] = [
            SIMD2(0.0, 1.528_664_8), SIMD2(0.0, 1.088_493_2), SIMD2(0.0, 0.868_407), SIMD2(0.074_911_41, 0.631_494),
            SIMD2(0.169_06, 0.372_824), SIMD2(0.372_824, 0.169_06), SIMD2(0.631_494, 0.074_911_41),
            SIMD2(0.868_407, 0.0), SIMD2(1.088_493_2, 0.0), SIMD2(1.528_664_8, 0.0),
        ]
        func polyline(_ r: Float) -> [SIMD2<Float>] {
            var points: [SIMD2<Float>] = []
            for start in stride(from: 0, to: 9, by: 3) {
                for k in 0..<64 {
                    let t = Float(k) / 64.0
                    let u = 1.0 - t
                    let b0 = u * u * u
                    let b1 = 3.0 * t * u * u
                    let b2 = 3.0 * t * t * u
                    let b3 = t * t * t
                    let pt = (curve[start] * b0 + curve[start + 1] * b1 + curve[start + 2] * b2 + curve[start + 3] * b3) * r
                    points.append(pt)
                }
            }
            points.append(curve[9] * r)
            return points
        }
        func oracle(_ p: SIMD2<Float>, _ line: [SIMD2<Float>]) -> Float {
            let e = line[line.count - 1].x
            if p.x >= e || p.y >= e { return max(-p.x, -p.y) }
            var bestDist = Float.greatestFiniteMagnitude
            var bestCross: Float = 0
            for idx in 0..<(line.count - 1) {
                let a = line[idx]
                let b = line[idx + 1]
                let ab = b - a
                let ap = p - a
                let t = min(max((ap.x * ab.x + ap.y * ab.y) / (ab.x * ab.x + ab.y * ab.y), 0.0), 1.0)
                let delta = ap - ab * t
                let d = hypotf(delta.x, delta.y)
                if d < bestDist {
                    bestDist = d
                    bestCross = ab.x * ap.y - ab.y * ap.x
                }
            }
            return bestCross > 0 ? -bestDist : bestDist
        }

        let r: Float = 14.0
        let line = polyline(r)
        let fill = RenderInstance(
            rect: SIMD4<Float>(8, 8, 72, 56),
            radii: SIMD4<Float>(repeating: -r),
            fill: SIMD4<Float>(1, 1, 1, 1),
            params: SIMD4<Float>(0, KIND_RECT, 0.5, 1)
        )
        var clipped = RenderInstance(
            rect: SIMD4<Float>(0, 0, 96, 80),
            fill: SIMD4<Float>(1, 1, 1, 1),
            params: SIMD4<Float>(0, KIND_RECT, 0.5, 1),
            clip: SIMD4<Float>(8, 8, 80, 64)
        )
        clipped.roundClip(-r)

        for instance in [fill, clipped] {
            let out = try renderer.renderOffscreen(
                RenderFrame(width: 96, height: 80, clearColor: .zero, instances: [instance])
            )
            var worst: Float = 0
            for y in 0..<80 {
                for x in 0..<96 {
                    let c = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    let p = SIMD2<Float>(min(c.x - 8.0, 80.0 - c.x), min(c.y - 8.0, 64.0 - c.y))
                    let want = min(max(0.5 - oracle(p, line), 0.0), 1.0)
                    let got = Float(sampleRGBA(out, x: x, y: y).a) / 255.0
                    worst = max(worst, abs(got - want))
                }
            }
            #expect(worst < 0.04, "coverage off Apple's continuous curve by \(worst)")
        }

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

        // `continuous_corners_at_half_the_shorter_side_stay_closed` (`continuous_corner_tests.rs:75`)
        let capInst = RenderInstance(
            rect: SIMD4<Float>(0, 0, 64, 32),
            radii: SIMD4<Float>(repeating: -100),
            fill: SIMD4<Float>(1, 1, 1, 1),
            params: SIMD4<Float>(0, KIND_RECT, 0, 1),
            clip: NO_CLIP
        )
        let capOut = try renderer.renderOffscreen(
            RenderFrame(width: 64, height: 32, clearColor: .zero, instances: [capInst])
        )
        #expect(sampleRGBA(capOut, x: 32, y: 16).a == 255)
        #expect(sampleRGBA(capOut, x: 32, y: 0).a == 255)
        #expect(sampleRGBA(capOut, x: 0, y: 0).a == 0)
        let capEndA = sampleRGBA(capOut, x: 0, y: 16).a
        #expect(capEndA > 64 && capEndA < 255)
    }

    @Test("BackdropBlurSchedule levels continuity and GPU parity (stripes, tint, cap, edge clamp, clip, HiDPI)")
    func backdropBlurScheduleAndGPUParity() throws {
        // `levels_cover_the_range_continuously` (`render/backdrop_blur_tests.rs:4`)
        let top = BackdropBlurSchedule.sigmas.count - 1
        #expect(BackdropBlurSchedule.levels(sigma: 0.0, top: top) == (1, 0.0))
        #expect(BackdropBlurSchedule.levels(sigma: BackdropBlurSchedule.sigmas[top] * 4.0, top: top) == (top, 1.0))
        var last: Float = 0.0
        for k in 1..<400 {
            let sigma = Float(k) * 0.5
            let (n, share) = BackdropBlurSchedule.levels(sigma: sigma, top: top)
            #expect(n >= 1 && n <= top)
            #expect(share >= 0.0 && share <= 1.0)
            let a = BackdropBlurSchedule.sigmas[n - 1]
            let b = BackdropBlurSchedule.sigmas[n]
            let got = sqrtf(a * a + share * (b * b - a * a))
            let expected = min(max(sigma, BackdropBlurSchedule.sigmas[0]), BackdropBlurSchedule.sigmas[top])
            #expect(abs(got - expected) < 1e-3, "sigma \(sigma): \(got)")
            #expect(got >= last)
            last = got
        }

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
        rtStripes.srgbBlend = false
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

        // `bleed_reaches_in_and_the_scissor_holds_the_clip` (`tests/effect_slot.rs:304`)
        let bgGrey = Color(r: 32.0 / 255.0, g: 32.0 / 255.0, b: 32.0 / 255.0, a: 1.0)
        let rtBleed = Runtime<S>(
            state: S(),
            viewport: Vec2(96, 96),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(96, 96)
                    .bg(bgGrey)
                    .child(
                        col()
                            .size(64, 64)
                            .absolute(x: 16, y: 16)
                            .clipFade(left: 0, top: 0, right: 0, bottom: 0)
                            .child(el().size(8, 8).absolute(x: -12, y: 0).effect(1).effectBleed(16))
                    )
            }
        )
        var bleedFrame = rtBleed.renderFrame(at: 0)
        bleedFrame.srgbBlend = false
        let bleedImg = try renderer.renderOffscreen(bleedFrame, hook: { encoder, site in
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
        let bgSample = sampleRGBA(bleedImg, x: 8, y: 8)
        let bleedIn = sampleRGBA(bleedImg, x: 20, y: 20)
        let bleedOutsideClip = sampleRGBA(bleedImg, x: 10, y: 20)
        let pastBleed = sampleRGBA(bleedImg, x: 20, y: 44)
        #expect(bleedIn.g > 200 && bleedIn.r < 20)
        #expect(bleedOutsideClip == bgSample)
        #expect(pastBleed == bgSample)
    }

    @Test("Single-phase EffectHook receives site.backdrop and isolates viewport/scissor (backdrop_tests.rs:51-76)")
    func singlePhaseEffectHookReceivesBackdropAndIsolatesState() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(32, 32),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(32, 32)
                    .child(el().size(32, 32).bg(Color(r: 1, g: 0, b: 0, a: 1)))
                    .child(
                        col()
                            .size(16, 16)
                            .absolute(x: 0, y: 0)
                            .clip()
                            .child(el().size(16, 16).effect(1).effectBackdrop(true))
                    )
                    .child(el().size(16, 32).absolute(x: 16, y: 0).bg(Color(r: 0, g: 1, b: 0, a: 1)))
            }
        )
        var frame = rt.renderFrame(at: 0)
        frame.srgbBlend = false

        var sawHookBackdrop = false
        let img = try renderer.renderOffscreen(frame, hook: { encoder, site in
            sawHookBackdrop = (site.backdrop != nil)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: 1, height: 1, znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: 1, height: 1))
        })
        #expect(sawHookBackdrop == true)
        let leftPx = sampleRGBA(img, x: 8, y: 24)
        let rightPx = sampleRGBA(img, x: 24, y: 24)
        #expect(leftPx.r > 245 && leftPx.g < 10 && leftPx.b < 10)
        #expect(rightPx.g > 245 && rightPx.r < 10 && rightPx.b < 10)

        // Also verify drawRangeWith(..., hook:) delivers site.backdrop != nil
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 32,
            height: 32,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        let target = try #require(renderer.device.makeTexture(descriptor: desc))
        let cb = try #require(renderer.commandQueue.makeCommandBuffer())
        var sawDrawRangeBackdrop = false
        renderer.drawRangeWith(frame: frame, into: target, commandBuffer: cb, hook: { _, site in
            sawDrawRangeBackdrop = (site.backdrop != nil)
        })
        cb.commit()
        cb.waitUntilCompleted()
        #expect(sawDrawRangeBackdrop == true)
    }

    @Test("Dashed border ring_arc matches WGSL perimeter (-bw) and sharp/rounded corner projection")
    func dashedBorderSharpAndRoundedParity() throws {
        let renderer = try MetalRenderer()
        struct S {}

        // 1. Sharp corners: 68x48 rect with bw=8 => centerline 60x40 => perimeter 200 = 10 periods of (10 dash + 10 gap).
        let rtSharp0 = Runtime<S>(
            state: S(),
            viewport: Vec2(68, 48),
            pixelScale: 1.0,
            view: { _, _ in
                el()
                    .size(68, 48)
                    .dashedBorder(8, .white, dash: 10, gap: 10, phase: 0)
            }
        )
        var fSharp0 = rtSharp0.renderFrame(at: 0)
        fSharp0.clearColor = .zero
        let sharp0 = try renderer.renderOffscreen(fSharp0)
        // Top edge: dash 0 covers s in [0, 10] (x=4..13), gap 0 covers s in [10, 20] (x=14..23), dash 1 at x=24
        #expect(sampleRGBA(sharp0, x: 4, y: 2).a > 200)
        #expect(sampleRGBA(sharp0, x: 14, y: 2).a < 15)
        #expect(sampleRGBA(sharp0, x: 24, y: 2).a > 200)
        // Sharp inner corner projection: top-left inner top (s=2.5, dash 0) is ON while just below corner on left edge (s=197.5, gap 9) is OFF
        #expect(sampleRGBA(sharp0, x: 6, y: 2).a > 200)
        #expect(sampleRGBA(sharp0, x: 2, y: 6).a < 15)
        // Right edge after -bw corner length (s_right = 60): y=4 -> s=60.5 (ON), y=14 -> s=70.5 (OFF), y=24 -> s=80.5 (ON)
        #expect(sampleRGBA(sharp0, x: 66, y: 4).a > 200)
        #expect(sampleRGBA(sharp0, x: 66, y: 14).a < 15)
        #expect(sampleRGBA(sharp0, x: 66, y: 24).a > 200)

        // Shifting phase by half a period (10 px) cleanly inverts dashes and gaps, including sharp inner corner & right edge
        let rtSharp10 = Runtime<S>(
            state: S(),
            viewport: Vec2(68, 48),
            pixelScale: 1.0,
            view: { _, _ in
                el()
                    .size(68, 48)
                    .dashedBorder(8, .white, dash: 10, gap: 10, phase: 10)
            }
        )
        var fSharp10 = rtSharp10.renderFrame(at: 0)
        fSharp10.clearColor = .zero
        let sharp10 = try renderer.renderOffscreen(fSharp10)
        #expect(sampleRGBA(sharp10, x: 4, y: 2).a < 15)
        #expect(sampleRGBA(sharp10, x: 6, y: 2).a < 15)
        #expect(sampleRGBA(sharp10, x: 2, y: 6).a > 200)
        #expect(sampleRGBA(sharp10, x: 14, y: 2).a > 200)
        #expect(sampleRGBA(sharp10, x: 66, y: 4).a < 15)
        #expect(sampleRGBA(sharp10, x: 66, y: 14).a > 200)

        // 2. Rounded capsule (border_dash.rs parity): 136x30 pill, bw=2, dash=16, gap=8
        let rtRounded = Runtime<S>(
            state: S(),
            viewport: Vec2(160, 60),
            pixelScale: 1.0,
            view: { _, _ in
                col()
                    .size(160, 60)
                    .child(
                        el()
                            .size(136, 30)
                            .absolute(x: 12, y: 15)
                            .pill()
                            .dashedBorder(2, .white, dash: 16, gap: 8, phase: 0)
                    )
            }
        )
        var fRounded = rtRounded.renderFrame(at: 0)
        fRounded.clearColor = .zero
        let rounded = try renderer.renderOffscreen(fRounded)
        // Top straight edge starts at x = 12 + 15 = 27: dash 0 covers s in [0, 15.38] (x=29 -> s=2.5), gap 0 covers [15.38, 23.07] (x=46 -> s=19.5)
        #expect(sampleRGBA(rounded, x: 29, y: 15).a > 180)
        #expect(sampleRGBA(rounded, x: 46, y: 15).a < 15)
        // Right rounded cap arc (center 133, 30, ring centerline radius 14): both ON and OFF samples exist along arc
        var arcLit = 0
        var arcDark = 0
        for deg in stride(from: 10, through: 170, by: 10) {
            let rad = Float(deg) * (.pi / 180.0)
            let px = Int((133.0 + 14.0 * sin(rad)).rounded())
            let py = Int((30.0 - 14.0 * cos(rad)).rounded())
            let a = sampleRGBA(rounded, x: px, y: py).a
            if a > 120 { arcLit += 1 }
            if a < 15 { arcDark += 1 }
        }
        #expect(arcLit > 0 && arcDark > 0)
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
        rtCached.update(at: 0.04) { s, tx in
            s.color = Color(r: 0, g: 0.2, b: 0.9, a: 1)
            tx.instant()
        }
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
        rtAnalytic.srgbBlend = false
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

    @Test("MetalRenderer.drawRange & drawRangeWith encode explicit subranges and skip empty upper-bound slices")
    func drawRangeSubrangeAndHookParity() throws {
        let renderer = try MetalRenderer()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 40,
            height: 20,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: desc))

        let instances = [
            RenderInstance(
                rect: SIMD4<Float>(2, 2, 14, 16),
                fill: SIMD4<Float>(1, 0, 0, 1),
                params: SIMD4<Float>(0, KIND_RECT, 0.5, 1)
            ),
            RenderInstance(
                rect: SIMD4<Float>(22, 2, 14, 16),
                fill: SIMD4<Float>(0, 1, 0, 1),
                params: SIMD4<Float>(0, KIND_RECT, 0.5, 1)
            ),
        ]
        let frame = RenderFrame(
            width: 40,
            height: 20,
            clearColor: SIMD4<Float>(0, 0, 0, 1),
            instances: instances
        )

        let cb1 = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.drawRange(frame: frame, into: target, commandBuffer: cb1, range: 0..<1)
        cb1.commit()
        cb1.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: 40 * 20 * 4)
        target.getBytes(&bgra, bytesPerRow: 40 * 4, from: MTLRegionMake2D(0, 0, 40, 20), mipmapLevel: 0)
        // Instance 0 drawn at (8, 10) -> red
        let p0 = (10 * 40 + 8) * 4
        #expect(bgra[p0 + 2] > 200 && bgra[p0 + 1] < 20)
        // Instance 1 outside range 0..<1 at (28, 10) -> stays black clear
        let p1 = (10 * 40 + 28) * 4
        #expect(bgra[p1 + 2] < 20 && bgra[p1 + 1] < 20)

        // Empty upper-bound subrange skips drawing & hook invocations cleanly
        let cb2 = try #require(renderer.commandQueue.makeCommandBuffer())
        var hookCalls = 0
        renderer.drawRangeWith(frame: frame, into: target, commandBuffer: cb2, range: 0..<0) { _, _ in
            hookCalls += 1
        }
        cb2.commit()
        cb2.waitUntilCompleted()
        #expect(hookCalls == 0)
    }

    @Test("AtlasUploader batches break only on bound page change and rebatch only on params/length/forget")
    func batchesBreakAndRebatchOnlyWhenNeeded() throws {
        let renderer = try MetalRenderer()
        func square(_ x: Float, _ y: Float) -> RenderInstance {
            RenderInstance(rect: SIMD4<Float>(x, y, 8, 8), fill: SIMD4<Float>(1, 1, 1, 1), params: SIMD4<Float>(0, KIND_RECT, 0.5, 1))
        }
        func withKind(_ kind: Float, page: Float) -> RenderInstance {
            RenderInstance(rect: SIMD4<Float>(0, 0, 8, 8), fill: SIMD4<Float>(1, 1, 1, 1), params: SIMD4<Float>(page, kind, 0, 0))
        }
        func glyph(_ page: Float) -> RenderInstance {
            RenderInstance(rect: SIMD4<Float>(0, 0, 8, 8), fill: SIMD4<Float>(1, 1, 1, 1), params: SIMD4<Float>(0, KIND_GLYPH, page, 0))
        }

        // `batches_break_only_where_the_bound_page_changes` (`upload/tests.rs:305`)
        let instances = [
            square(0, 0), withKind(KIND_IMAGE, page: 1), square(0, 0), withKind(KIND_SHADOW, page: 0),
            glyph(2), withKind(KIND_GRADIENT, page: 0), glyph(0), square(0, 0), withKind(KIND_IMAGE, page: 1),
        ]
        renderer.uploader.prepareBatches(instances: instances, glyphPageCount: 2, imagePageCount: 2)
        let gotBatches = renderer.uploader.imageBatches
        #expect(gotBatches.count == 5)
        #expect(gotBatches[0].0 == 0..<1 && gotBatches[0].1 == .image(0))
        #expect(gotBatches[1].0 == 1..<4 && gotBatches[1].1 == .image(1))
        #expect(gotBatches[2].0 == 4..<6 && gotBatches[2].1 == .glyph(1))
        #expect(gotBatches[3].0 == 6..<8 && gotBatches[3].1 == .image(0))
        #expect(gotBatches[4].0 == 8..<9 && gotBatches[4].1 == .image(1))

        // `only_a_changed_params_or_length_batches_again` (`upload/tests.rs:327`)
        renderer.uploader.forgetInstances()
        func makeFrame(x: Float, page: Float, extra: Int) -> [RenderInstance] {
            var list = [
                square(x, 0),
                RenderInstance(rect: SIMD4<Float>(x, 8, 8, 8), fill: SIMD4<Float>(1, 1, 1, 1), params: SIMD4<Float>(page, KIND_IMAGE, 0, 0)),
                RenderInstance(rect: SIMD4<Float>(x, 16, 8, 8), fill: SIMD4<Float>(1, 1, 1, 1), params: SIMD4<Float>(0, KIND_EFFECT, 0, 0)),
            ]
            for i in 0..<extra {
                list.append(square(Float(i), 24))
            }
            return list
        }
        func prepareStep(_ list: [RenderInstance]) -> (deltaRuns: UInt64, batches: [(Range<Int>, Bool)], effects: [(Int, Float)]) {
            let before = renderer.uploader.batchRuns
            renderer.uploader.prepareBatches(instances: list, glyphPageCount: 2, imagePageCount: 2)
            let batches = renderer.uploader.imageBatches.map { ($0.0, $0.1 == .image(1)) }
            let effs = renderer.uploader.effects.map { ($0.0, $0.1.rect.x) }
            return (renderer.uploader.batchRuns - before, batches, effs)
        }

        let r0 = prepareStep(makeFrame(x: 0, page: 1, extra: 0))
        #expect(r0.deltaRuns == 1 && r0.batches.count == 2 && r0.batches[0].0 == 0..<1 && !r0.batches[0].1 && r0.batches[1].0 == 1..<3 && r0.batches[1].1)
        #expect(r0.effects.count == 1 && r0.effects[0] == (2, 0))

        let rMoved = prepareStep(makeFrame(x: 5, page: 1, extra: 0))
        #expect(rMoved.deltaRuns == 0 && rMoved.effects.count == 1 && rMoved.effects[0] == (2, 5))

        let rPageChanged = prepareStep(makeFrame(x: 5, page: 0, extra: 0))
        #expect(rPageChanged.deltaRuns == 1 && rPageChanged.batches.count == 1 && rPageChanged.batches[0].0 == 0..<3 && !rPageChanged.batches[0].1)

        let rLonger = prepareStep(makeFrame(x: 5, page: 0, extra: 2))
        #expect(rLonger.deltaRuns == 1)

        renderer.uploader.forgetInstances()
        let rForgotten = prepareStep(makeFrame(x: 5, page: 0, extra: 2))
        #expect(rForgotten.deltaRuns == 1)

        let rEmpty = prepareStep([])
        #expect(rEmpty.deltaRuns == 1 && rEmpty.batches.isEmpty && rEmpty.effects.isEmpty)
    }

    @Test("Clipped-out and offscreen KIND_EFFECT slots skip hook cleanly without hanging and preserve later draws")
    func clippedOutAndOffscreenEffectSlotsSkipWithoutHanging() throws {
        let renderer = try MetalRenderer()
        let instances = [
            RenderInstance(
                rect: SIMD4<Float>(2, 2, 10, 16),
                fill: SIMD4<Float>(0, 1, 0, 1),
                params: SIMD4<Float>(0, KIND_RECT, 0.5, 1)
            ),
            // Clipped-out effect slot (rect completely outside clip rect)
            RenderInstance(
                rect: SIMD4<Float>(10, 10, 10, 10),
                params: SIMD4<Float>(0, KIND_EFFECT, 0, 1),
                clip: SIMD4<Float>(0, 0, 5, 5)
            ),
            // Offscreen effect slot (rect completely outside 40x20 viewport)
            RenderInstance(
                rect: SIMD4<Float>(50, 50, 10, 10),
                params: SIMD4<Float>(0, KIND_EFFECT, 0, 2)
            ),
            RenderInstance(
                rect: SIMD4<Float>(25, 2, 10, 16),
                fill: SIMD4<Float>(0, 0, 1, 1),
                params: SIMD4<Float>(0, KIND_RECT, 0.5, 1)
            ),
        ]
        let frame = RenderFrame(
            width: 40,
            height: 20,
            clearColor: SIMD4<Float>(0, 0, 0, 1),
            instances: instances
        )
        var hookCalls = 0
        let img = try renderer.renderOffscreen(frame, hook: { _, _ in
            hookCalls += 1
        })
        #expect(hookCalls == 0)
        // Green rect at (6, 10) and blue rect at (30, 10) still render cleanly after skipped effects
        let g = img.pixel(x: 6, y: 10)
        #expect(g.y > 200 && g.x < 20 && g.z < 20)
        let b = img.pixel(x: 30, y: 10)
        #expect(b.z > 200 && b.x < 20 && b.y < 20)
    }
}
#endif
