import Foundation
import Testing
@testable import Rune
@testable import RuneLight
#if canImport(Metal)
@preconcurrency import Metal
#endif
#if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
import CRuneGL
import CRuneOffscreenGL
#endif

/// Continuous corners (negative radii) in `RuneLight`'s shaders (`commonPrelude`, `glassShader`,
/// GLSL `common.glsl`, `glass.frag`) and CPU reference (`RuneLightCPU`) must match Rune's uber
/// shader (`sd_rounded`). Mirrors upstream `crates/rune-light/tests/continuous_corners.rs`.
@Suite("RuneLight Continuous Corners Parity Tests")
struct RuneLightContinuousCornersTests {
    private static let width = 96
    private static let height = 80

    @Test("RuneLightCPU.sdRoundedRect evaluates continuous corners for negative radii")
    func cpuContinuousCornersCutCornerAndMatchStraightEdges() {
        let rect = SIMD4<Float>(8, 8, 80, 64)
        let cont = Prim.fromRune(rect: rect, radii: SIMD4<Float>(repeating: -20.0)).raised(16.0)
        let circ = Prim.fromRune(rect: rect, radii: SIMD4<Float>(repeating: 20.0)).raised(16.0)

        // Straight edge midpoint (top edge, x=48, y=8): both continuous and circular are on boundary (d == 0).
        #expect(abs(RuneLightCPU.primSD(cont, at: SIMD2<Float>(48, 8))) < 1e-4)
        #expect(abs(RuneLightCPU.primSD(circ, at: SIMD2<Float>(48, 8))) < 1e-4)

        // Deep center (48, 40): both are -32 (half-height).
        #expect(abs(RuneLightCPU.primSD(cont, at: SIMD2<Float>(48, 40)) + 32.0) < 1e-4)

        // Near corner (11, 11): 3 px inside sharp corner (8, 8), outside continuous r=20 corner.
        let cornerD = RuneLightCPU.field(prims: [cont], at: SIMD2<Float>(11.0, 11.0)).x
        #expect(cornerD > 3.0)

        // Mixed radii: top-left continuous (-20), top-right circular (12), bottom-right continuous (-10), bottom-left sharp (0).
        let mixed = Prim.fromRune(rect: rect, radii: SIMD4<Float>(-20.0, 12.0, -10.0, 0.0)).raised(16.0)
        #expect(RuneLightCPU.primSD(mixed, at: SIMD2<Float>(11.0, 11.0)) > 3.0) // TL continuous cuts corner
        #expect(RuneLightCPU.primSD(mixed, at: SIMD2<Float>(11.0, 69.0)) < -2.0) // BL sharp keeps corner inside
    }

    #if canImport(Metal)
    private func solidTexture(
        device: MTLDevice,
        queue: MTLCommandQueue,
        format: MTLPixelFormat,
        color: MTLClearColor
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: Self.width,
            height: Self.height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let tex = try #require(device.makeTexture(descriptor: desc))
        let cmd = try #require(queue.makeCommandBuffer())
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = color
        rpd.colorAttachments[0].storeAction = .store
        let enc = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return tex
    }

    private func readRGBA8(from tex: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(
                raw.baseAddress!,
                bytesPerRow: tex.width * 4,
                from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                mipmapLevel: 0
            )
        }
        return out
    }

    private func readPrivateRGBA16F(
        device: MTLDevice,
        queue: MTLCommandQueue,
        tex: MTLTexture
    ) throws -> [SIMD4<Float>] {
        let w = tex.width
        let h = tex.height
        let rowBytes = w * 8
        let padded = ((rowBytes + 255) / 256) * 256
        let buf = try #require(device.makeBuffer(length: padded * h, options: .storageModeShared))
        let cmd = try #require(queue.makeCommandBuffer())
        let blit = try #require(cmd.makeBlitCommandEncoder())
        blit.copy(
            from: tex,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: buf,
            destinationOffset: 0,
            destinationBytesPerRow: padded,
            destinationBytesPerImage: padded * h
        )
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)

        let raw = UnsafeRawBufferPointer(start: buf.contents(), count: padded * h)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(w * h)
        for y in 0..<h {
            let rowStart = y * padded
            for x in 0..<w {
                let off = rowStart + x * 8
                func readF16(_ delta: Int) -> Float {
                    let lo = UInt16(raw[off + delta])
                    let hi = UInt16(raw[off + delta + 1])
                    return Float(Float16(bitPattern: lo | (hi << 8)))
                }
                out.append(SIMD4<Float>(readF16(0), readF16(2), readF16(4), readF16(6)))
            }
        }
        return out
    }

    private func renderUberRect(
        renderer: MetalRenderer,
        rect: SIMD4<Float>,
        radii: SIMD4<Float>
    ) throws -> [UInt8] {
        let inst = RenderInstance(
            rect: rect,
            radii: radii,
            fill: SIMD4<Float>(1, 1, 1, 1),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        let frame = RenderFrame(
            width: Self.width,
            height: Self.height,
            srgbBlend: false,
            clearColor: .zero,
            instances: [inst]
        )
        return try renderer.renderOffscreen(frame).rgba
    }

    @Test("LightRenderer gbuffer, distance field, and RuneLightCPU match Rune continuous corners")
    func lightGbufferFieldAndCpuMatchRuneContinuousCorners() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let uberRenderer = try MetalRenderer()

        let rect = SIMD4<Float>(8, 8, 80, 64)
        let cases: [(String, SIMD4<Float>)] = [
            ("uniform-continuous", SIMD4<Float>(repeating: -20.0)),
            ("mixed-continuous", SIMD4<Float>(-20.0, 12.0, -10.0, 0.0)),
        ]

        let baseTex = try solidTexture(
            device: device,
            queue: queue,
            format: .rgba16Float,
            color: MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        )
        let textTex = try solidTexture(
            device: device,
            queue: queue,
            format: .rgba16Float,
            color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        )
        let outTex = try solidTexture(
            device: device,
            queue: queue,
            format: .rgba8Unorm,
            color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        let light = try LightRenderer(
            device: device,
            width: UInt32(Self.width),
            height: UInt32(Self.height),
            outputFormat: .rgba8Unorm
        )

        for (name, radii) in cases {
            let uber = try renderUberRect(renderer: uberRenderer, rect: rect, radii: radii)
            let prim = Prim.fromRune(rect: rect, radii: radii).raised(16.0).emissive(SIMD3<Float>(1, 1, 1))
            // Zero ambient + zero-intensity light isolates gbuffer surface ownership (`emissive`
            // lights `base` wherever `gbuffer` keeps the pixel with `d <= 0.5`).
            let lights = [Light.point(48.0, 40.0, 100.0).intensity(0.0)]
            let settings = LightSettings(
                ambient: .zero,
                backgroundGloss: 0.0,
                contactAO: 0.0,
                rim: 0.0,
                albedoFloor: 0.0
            )
            let scene = LightScene(prims: [prim], lights: lights, settings: settings)
            let cmd = try #require(queue.makeCommandBuffer())
            #expect(light.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: outTex))
            cmd.commit()
            cmd.waitUntilCompleted()
            #expect(cmd.status == .completed)
            let lit = readRGBA8(from: outTex)

            // 1. Compare gbuffer surface silhouette inside the primitive's rect against Rune's
            //    uber shader continuous-corner mask.
            var mismatches = 0
            var first: (Int, Int, UInt8, UInt8)?
            for y in 8..<72 {
                for x in 8..<88 {
                    let i = (y * Self.width + x) * 4
                    let uberA = uber[i + 3]
                    let litR = lit[i]
                    let uberInside = uberA > 5
                    let uberOutside = uberA == 0
                    let litInside = litR > 100
                    if (uberInside && !litInside) || (uberOutside && litInside) {
                        mismatches += 1
                        if first == nil {
                            first = (x, y, uberA, litR)
                        }
                    }
                }
            }
            #expect(
                mismatches == 0,
                "\(name): rune-light gbuffer silhouette drifted from uber shader: \(mismatches) pixels, first=\(String(describing: first))"
            )

            // 2. Compare GPU `field` SDF against `RuneLightCPU.field` AND check that the
            //    continuous corner actually cuts the corner (positive SDF at (11, 11)).
            let (fw, fh) = (Int(light.fieldSize.0), Int(light.fieldSize.1))
            let gpuField = try readPrivateRGBA16F(device: device, queue: queue, tex: light.inspect().field)
            var maxSdErr: Float = 0.0
            var worstSd: (Int, Int, Float, Float)?
            for fy in 0..<fh {
                for fx in 0..<fw {
                    let p = SIMD2<Float>((Float(fx) + 0.5) * 2.0, (Float(fy) + 0.5) * 2.0)
                    let cpuD = RuneLightCPU.field(prims: [prim], at: p).x
                    let gpuD = gpuField[fy * fw + fx].x
                    let err = abs(cpuD - gpuD)
                    if err > maxSdErr {
                        maxSdErr = err
                        worstSd = (fx, fy, cpuD, gpuD)
                    }
                }
            }
            #expect(
                maxSdErr < 0.05,
                "\(name): GPU field SDF drifted from RuneLightCPU.field: maxErr=\(maxSdErr) worst=\(String(describing: worstSd))"
            )
            // Pixel (11, 11) is 3 px inside the sharp corner (8, 8): outside a continuous r=20 corner.
            let cornerCpu = RuneLightCPU.field(prims: [prim], at: SIMD2<Float>(11.0, 11.0)).x
            let cornerGpu = gpuField[5 * fw + 5].x
            #expect(
                cornerCpu > 3.0 && cornerGpu > 3.0,
                "\(name): continuous corner at (11,11) must have positive SDF (outside shape), got cpu=\(cornerCpu) gpu=\(cornerGpu)"
            )
        }
    }

    @Test("GlassRenderer continuous corners match Rune uber shader")
    func glassContinuousCornersMatchRuneUberShader() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let uberRenderer = try MetalRenderer()

        let rect = SIMD4<Float>(8, 8, 80, 64)
        let uber = try renderUberRect(renderer: uberRenderer, rect: rect, radii: SIMD4<Float>(repeating: -20.0))

        // Pure red backdrop, opaque-absorbing glass with zero env/shadow/caustic: outside glass
        // stays red (255), inside glass goes black (0), edge coverage blends linearly with clamp(0.5 - d).
        let backdrop = try solidTexture(
            device: device,
            queue: queue,
            format: .rgba16Float,
            color: MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let black = try solidTexture(
            device: device,
            queue: queue,
            format: .rgba16Float,
            color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        let out = try solidTexture(
            device: device,
            queue: queue,
            format: .rgba8Unorm,
            color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        let glass = try GlassRenderer(
            device: device,
            width: UInt32(Self.width),
            height: UInt32(Self.height),
            pixelFormat: .rgba8Unorm
        )
        let slab = Glass.rounded(rect.x, rect.y, rect.z, rect.w, radius: -20.0)
            .thickness(24.0)
            .bevel(1.0)
            .gap(4.0)
            .tint(SIMD3<Float>(10.0, 10.0, 10.0))
            .rimGlow(0.0)
        let settings = GlassSettings(env: 0.0, shadow: 0.0, caustic: 0.0)
        let cmd = try #require(queue.makeCommandBuffer())
        try glass.render(
            commandBuffer: cmd,
            glass: [slab],
            lights: [],
            settings: settings,
            backdrop: backdrop,
            fluence: black,
            target: out
        )
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)
        let px = readRGBA8(from: out)

        var mismatches = 0
        var first: (Int, Int, UInt8, UInt8)?
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let i = (y * Self.width + x) * 4
                let uberA = uber[i + 3]
                let glassCov = UInt8(max(0, 255 - Int(px[i])))
                let deepInside: Bool = x >= 10 && x < 86 && y >= 10 && y < 70 && uberA == 255 && {
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let ni = ((y + dy) * Self.width + (x + dx)) * 4
                            if uber[ni + 3] != 255 {
                                return false
                            }
                        }
                    }
                    return true
                }()
                if (uberA == 0 && glassCov > 10) || (deepInside && glassCov < 200) {
                    mismatches += 1
                    if first == nil {
                        first = (x, y, uberA, px[i])
                    }
                }
            }
        }
        #expect(
            mismatches == 0,
            "glass shader continuous corner drifted from uber shader: \(mismatches) pixels, first=\(String(describing: first))"
        )
    }
    #endif

    #if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
    @Test("GL LightGLRenderer and GlassGLRenderer cut continuous corners cleanly")
    func glLightAndGlassContinuousCorners() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let lightGL = try LightGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { lightGL.close() }
        let glassGL = try GlassGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { glassGL.close() }

        var errors = [CChar](repeating: 0, count: 512)
        let cap = errors.count
        let passes = try #require(rune_gl_pass_open(OffscreenGLContext.resolve, &errors, cap))
        defer { rune_gl_pass_close(passes) }

        let w = Self.width
        let h = Self.height
        let greyPixels = [UInt8](repeating: 128, count: w * h * 4)
        let baseTex = rune_gl_pass_texture(passes, RuneGLPassRGBA8, Int32(w), Int32(h), greyPixels, 1, &errors, cap)
        try #require(baseTex != 0)
        defer { rune_gl_pass_delete_texture(passes, baseTex) }

        let rect = SIMD4<Float>(8, 8, 80, 64)
        let prim = Prim.fromRune(rect: rect, radii: SIMD4<Float>(repeating: -20.0)).raised(16.0).emissive(SIMD3<Float>(1, 1, 1))
        let scene = LightScene(
            prims: [prim],
            lights: [Light.point(48, 40, 100).intensity(0.0)],
            settings: LightSettings(ambient: .zero, backgroundGloss: 0, contactAO: 0, rim: 0, albedoFloor: 0)
        )
        let litFrame = try context.withFramebuffer(width: w, height: h) {
            let rendered = try lightGL.render(scene: scene, width: w, height: h, baseTexture: baseTex, textTexture: 0)
            #expect(rendered)
        }
        // Center is inside the continuous rect (emissive lit), corner (11, 11) is cut outside (dark).
        #expect(litFrame.pixel(x: 48, y: 40).x > 100)
        #expect(litFrame.pixel(x: 11, y: 11).x < 10)

        var redPixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: redPixels.count, by: 4) {
            redPixels[i] = 255
            redPixels[i + 3] = 255
        }
        let redTex = rune_gl_pass_texture(passes, RuneGLPassRGBA8, Int32(w), Int32(h), redPixels, 1, &errors, cap)
        try #require(redTex != 0)
        defer { rune_gl_pass_delete_texture(passes, redTex) }

        let slab = Glass.rounded(rect.x, rect.y, rect.z, rect.w, radius: -20.0)
            .thickness(24.0)
            .bevel(1.0)
            .gap(4.0)
            .tint(SIMD3<Float>(10.0, 10.0, 10.0))
            .rimGlow(0.0)
        let glassFrame = try context.withFramebuffer(width: w, height: h) {
            try glassGL.render(
                glass: [slab],
                settings: GlassSettings(env: 0, shadow: 0, caustic: 0),
                width: w,
                height: h,
                backdrop: redTex
            )
        }
        // Outside continuous corner (11, 11) remains bright red; deep inside (48, 40) is absorbed dark.
        #expect(glassFrame.pixel(x: 11, y: 11).x > 245)
        #expect(glassFrame.pixel(x: 48, y: 40).x < 55)
    }
    #endif
}
