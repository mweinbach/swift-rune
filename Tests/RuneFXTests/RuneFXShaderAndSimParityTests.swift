import Foundation
import Testing
@testable import RuneFX

#if canImport(Metal)
import Metal
#endif

private func f16ToF32(_ h: UInt16) -> Float {
    let s = UInt32(h >> 15)
    let e = Int((h >> 10) & 0x1f)
    let m = Float(h & 0x3ff)
    let v: Float
    switch e {
    case 0:
        v = m * powf(2.0, -24.0)
    case 31:
        v = m == 0 ? .infinity : .nan
    default:
        v = (1.0 + m / 1024.0) * powf(2.0, Float(e - 15))
    }
    return s == 1 ? -v : v
}

private func isFiniteF16(_ h: UInt16) -> Bool {
    (h & 0x7c00) != 0x7c00
}

@Suite("RuneFX Shaders, Fills & FireSim Parity Tests")
struct RuneFXShaderAndSimParityTests {
    @Test("Metal uniform struct strides match shader layouts")
    func uniformStructStridesMatchShaders() {
        #expect(MemoryLayout<FireSimUniform>.stride == 96)
        #expect(MemoryLayout<FireSimKernelParams>.stride == 16)
        #expect(MemoryLayout<FxGlobals>.stride == 16)
        #expect(MemoryLayout<FxBackdropEncoding>.stride == 16)
        #expect(MemoryLayout<FxInstRaw>.stride == 256)
    }

    @Test("FireSim claim isolation, expiry, and hitch/warmup scheduling")
    func fireSimClaimIsolationAndHitchScheduling() {
        let key = FireSimKey(seed: 1, style: 0, width: 40, height: 30)
        var claims: [FireSimClaim] = []

        func claimAt(_ origin: SIMD2<Float>, frame: UInt64) -> Int {
            if let idx = FireSim.pickGrid(claims: claims, key: key, origin: origin, frame: frame) {
                claims[idx] = FireSimClaim(key: key, origin: origin, usedFrame: frame)
                return idx
            }
            claims.append(FireSimClaim(key: key, origin: origin, usedFrame: frame))
            return claims.count - 1
        }

        let a = claimAt(SIMD2<Float>(0, 0), frame: 1)
        let b = claimAt(SIMD2<Float>(300, 0), frame: 1)
        #expect(a != b)
        #expect(claimAt(SIMD2<Float>(302, 1), frame: 2) == b)
        #expect(claimAt(SIMD2<Float>(1, 0), frame: 2) == a)
        #expect(claims.count == 2)

        _ = claimAt(SIMD2<Float>(1, 0), frame: 3)
        claims.removeAll { !$0.isAlive(at: 4) }
        #expect(claims.count == 1)
        #expect(claims[0].origin == SIMD2<Float>(1, 0))

        let warm = Int((FireSim.warmupSeconds / FireSim.dt).rounded())
        let (n0, s0) = FireSim.schedule(prev: nil, target: 3.0, frozen: false)
        #expect(s0.isReset && n0 == warm)

        let (n1, s1) = FireSim.schedule(prev: 1.0, target: 1.0 + 2.5 * FireSim.dt, frozen: false)
        #expect(!s1.isReset && n1 == 2 && abs(s1.t0 - (1.0 + 0.5 * FireSim.dt)) < 1e-5)

        let (n2, s2) = FireSim.schedule(prev: 1.0, target: 3.0, frozen: false)
        #expect(!s2.isReset && n2 == FireSim.maxSteps)
        #expect(abs(s2.t0 + Float(FireSim.maxSteps) * FireSim.dt - 3.0) < 1e-5)

        #expect(FireSim.schedule(prev: 2.0, target: 1.0, frozen: false).start.isReset)
        #expect(FireSim.schedule(prev: 1.0, target: 3.0, frozen: true).steps == 0)
    }

    #if canImport(Metal)
    private func makeSharedTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        format: MTLPixelFormat = .rgba16Float,
        usage: MTLTextureUsage = [.renderTarget, .shaderRead]
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .shared
        return try #require(device.makeTexture(descriptor: desc))
    }

    private func readRGBA16FloatWords(from tex: MTLTexture) -> [UInt16] {
        var words = [UInt16](repeating: 0, count: tex.width * tex.height * 4)
        words.withUnsafeMutableBytes { raw in
            tex.getBytes(
                raw.baseAddress!,
                bytesPerRow: tex.width * 8,
                from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                mipmapLevel: 0
            )
        }
        return words
    }

    private func readRGBA16Float(from tex: MTLTexture) -> [SIMD4<Float>] {
        let words = readRGBA16FloatWords(from: tex)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(tex.width * tex.height)
        for i in stride(from: 0, to: words.count, by: 4) {
            out.append(SIMD4<Float>(
                f16ToF32(words[i]),
                f16ToF32(words[i + 1]),
                f16ToF32(words[i + 2]),
                f16ToF32(words[i + 3])
            ))
        }
        return out
    }

    private func renderF16(
        renderer: FxRenderer,
        queue: MTLCommandQueue,
        target: MTLTexture,
        viewport: SIMD2<UInt32>,
        scale: Float,
        srgb: Bool,
        origin: SIMD2<Float> = .zero,
        layers: [FxLayer],
        backdrop: MTLTexture? = nil,
        sources: [MTLTexture?] = [],
        blurFirst: Bool = false
    ) throws -> [UInt16] {
        renderer.setSrgbBlend(srgb)
        let stats = renderer.prepare(
            frame: FxFrame(
                viewport: viewport,
                scale: scale,
                layers: layers,
                backdrop: backdrop,
                sources: sources
            )
        ).stats
        #expect(stats.drawn == UInt32(layers.count))

        let cmd = try #require(queue.makeCommandBuffer())
        if blurFirst, let bd = backdrop {
            for idx in layers.indices {
                _ = try renderer.blurBackdrop(commandBuffer: cmd, backdrop: bd, layer: idx)
            }
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        let pass = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
        for idx in layers.indices {
            try renderer.drawLayer(encoder: pass, format: .rgba16Float, origin: origin, layer: idx)
        }
        pass.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)
        return readRGBA16FloatWords(from: target)
    }

    @Test("All GPU fills are finite across extremes, large times, and degenerate inputs")
    func gpuFillsAreFiniteAtExtremesDegenerateParamsAndLargeTime() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        let renderer = try FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: true, srgbBlend: false))
        let w = 32
        let h = 32
        let target = try makeSharedTexture(device: device, width: w, height: h)
        let bd = try makeSharedTexture(device: device, width: w, height: h)
        let src = try makeSharedTexture(device: device, width: w, height: h)

        let clearCmd = try #require(queue.makeCommandBuffer())
        for (tex, col) in [(bd, MTLClearColor(red: 0.25, green: 0.4, blue: 0.6, alpha: 1)),
                           (src, MTLClearColor(red: 0.7, green: 0.3, blue: 0.2, alpha: 1))] {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = col
            rpd.colorAttachments[0].storeAction = .store
            clearCmd.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
        }
        clearCmd.commit()
        clearCmd.waitUntilCompleted()

        let shape = FxShape.rounded(x: 2, y: 2, w: 28, h: 28, radius: 6)
        func checkFinite(_ layer: FxLayer, blur: Bool = false) throws -> [UInt16] {
            let words = try renderF16(
                renderer: renderer,
                queue: queue,
                target: target,
                viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)),
                scale: 1.0,
                srgb: false,
                layers: [layer],
                backdrop: bd,
                sources: [src],
                blurFirst: blur
            )
            for word in words {
                #expect(isFiniteF16(word), "Non-finite f16 pixel \(word)")
            }
            return words
        }

        let paletteStops = Stops.hex([0x112233, 0x445566, 0x778899, 0xaabbcc, 0xddeeff, 0xff8800])
        let fillStyles: [(String, FillStyle, FillStyle)] = [
            ("liquidMetal",
             .liquidMetal(LiquidMetalParams(flow: 0, scale: 8, speed: 0, bevel: 0.5, dome: -1, angle: -3.14, iridescence: 0, contrast: 0.2)),
             .liquidMetal(LiquidMetalParams(flow: 1.5, scale: 240, speed: 2, bevel: 40, dome: 1, angle: 3.14, iridescence: 1, contrast: 2.5, anchor: .element))),
            ("meshGradient",
             .meshGradient(MeshGradientParams(colors: Stops(Array(paletteStops.colors.prefix(2))), drift: 0, speed: 0, sharpness: 0.1, warp: 0)),
             .meshGradient(MeshGradientParams(colors: paletteStops, drift: 0.5, speed: 2, sharpness: 8, warp: 1))),
            ("dither",
             .dither(DitherParams(pattern: .bayer2, input: .linear, colors: Stops(Array(paletteStops.colors.prefix(2))), pixel: 0.5, bias: -0.5, contrast: 0.5)),
             .dither(DitherParams(pattern: .white, input: .backdrop, colors: paletteStops, pixel: 8, bias: 0.5, contrast: 2.5))),
            ("grainGradient",
             .grainGradient(GrainGradientParams(kind: .linear, colors: Stops(Array(paletteStops.colors.prefix(2))), amount: 0, size: 0.25, mono: true, fps: 0)),
             .grainGradient(GrainGradientParams(kind: .conic, colors: paletteStops, angle: 3.14, center: SIMD2<Float>(0.5, 0.5), amount: 1, size: 8, mono: false, fps: 24))),
            ("flutedGlass",
             .flutedGlass(FlutedGlassParams(rib: 2, angle: 0, refraction: 0, frost: 0, dispersion: 0, highlight: 0, tintAmount: 0)),
             .flutedGlass(FlutedGlassParams(rib: 40, angle: 1.5, refraction: 24, frost: 1, dispersion: 1, highlight: 1, tint: rgb(0xff8844), tintAmount: 0.5))),
            ("metaballs",
             .metaballs(MetaballParams(colors: Stops(Array(paletteStops.colors.prefix(2))), count: 1, size: 0.05, speed: 0, gloss: 0)),
             .metaballs(MetaballParams(colors: paletteStops, count: 10, size: 0.6, speed: 2, gloss: 1))),
            ("swirl",
             .swirl(SwirlParams(colors: Stops(Array(paletteStops.colors.prefix(2))), scale: 10, speed: 0, twist: -2, warp: 0)),
             .swirl(SwirlParams(colors: paletteStops, scale: 300, speed: 2, twist: 2, warp: 2))),
            ("voronoi",
             .voronoi(VoronoiParams(colors: Stops(Array(paletteStops.colors.prefix(2))), scale: 4, speed: 0, edge: 0, depth: 0)),
             .voronoi(VoronoiParams(colors: paletteStops, scale: 80, speed: 2, edge: 6, depth: 1))),
            ("waves",
             .waves(WaveParams(colors: Stops(Array(paletteStops.colors.prefix(2))), amplitude: 0, frequency: 0.2, speed: 0, angle: -1.5, softness: 0)),
             .waves(WaveParams(colors: paletteStops, amplitude: 0.3, frequency: 6, speed: 2, angle: 1.5, softness: 0.2))),
            ("halftone",
             .halftone(HalftoneParams(input: .linear, cell: 2, angle: 0, rampAngle: 0, bias: -0.5, contrast: 0.5)),
             .halftone(HalftoneParams(input: .image, cell: 12, angle: 3.14, rampAngle: 1.5, bias: 0.5, contrast: 2.5))),
            ("plastic",
             .plastic(PlasticParams(color: rgb(0x202226), roughness: 0, dome: -1, bevel: 0.5, angle: -3.14)),
             .plastic(PlasticParams(color: rgb(0xffffff), roughness: 1, dome: 1, bevel: 40, angle: 3.14))),
        ]

        for (name, minStyle, maxStyle) in fillStyles {
            _ = try checkFinite(Fx.fill(FillParams(minStyle)).on(shape).source(slot: 0, rect: FxRect(x: 2, y: 2, w: 28, h: 28)).at(0.5))
            _ = try checkFinite(Fx.fill(FillParams(maxStyle)).on(shape).source(slot: 0, rect: FxRect(x: 2, y: 2, w: 28, h: 28)).at(0.5), blur: true)
            let f0 = try checkFinite(Fx.fill(FillParams(maxStyle)).on(shape).at(1e5))
            let f1 = try checkFinite(Fx.fill(FillParams(maxStyle)).on(shape).at(1e5 + 0.25))
            if name != "plastic" && name != "dither" && name != "flutedGlass" && name != "halftone" {
                #expect(f0 != f1, "\(name) should animate at t = 1e5")
            }
        }

        // Degenerate shapes, zero-size rects, and NaN/Inf fields.
        let pixelCenter = FxShape.rounded(x: 0.5, y: 0.5, w: 20, h: 20, radius: 0)
        _ = try checkFinite(Fx.fill(FillParams(.grainGradient(GrainGradientParams(kind: .conic, center: SIMD2<Float>(0.5, 0.5))))).on(pixelCenter).at(1.0))
        _ = try checkFinite(Fx.fill(FillParams(.metaballs(MetaballParams(size: 0)))).on(shape).at(1.0))
        _ = try checkFinite(Fx.fill(FillParams(.meshGradient(MeshGradientParams(sharpness: 50)))).on(shape).at(1.0))
        _ = try checkFinite(Fx.fill(FillParams(.dither(DitherParams(input: .image)))).on(shape).source(slot: 0, rect: FxRect(x: 0, y: 0, w: 0, h: 0)).at(1.0))
        for tiny in [FxShape.rounded(x: 2, y: 2, w: 4, h: 4, radius: 2), FxShape.rounded(x: 2.5, y: 2.5, w: 1, h: 1, radius: 0.5)] {
            _ = try checkFinite(Fx.fill(FillParams(.plastic(PlasticParams(roughness: 0, dome: 1, bevel: 48)))).on(tiny))
            _ = try checkFinite(Fx.fill(FillParams(.plastic(PlasticParams(roughness: 1, dome: -1, bevel: 48)), border: 20)).on(tiny))
            _ = try checkFinite(Fx.fill(FillParams(.liquidMetal(LiquidMetalParams(bevel: 48, dome: -1, anchor: .element)))).on(tiny).at(1.0))
        }
        _ = try checkFinite(Fx.fill(FillParams(.plastic(PlasticParams(roughness: .nan, dome: .infinity, bevel: .nan, angle: -.infinity)))).on(shape))
        _ = try checkFinite(Fx.fill(FillParams(.liquidMetal(LiquidMetalParams(flow: .nan, scale: .nan, bevel: .infinity, dome: .nan, contrast: .nan)))).on(shape).at(1.0))
    }

    @Test("Plastic coverage and highlight follow roughness and light direction")
    func plasticCoverageAndHighlightFollowRoughnessAndLight() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        let renderer = try FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: false, srgbBlend: false))
        let w = 128
        let h = 128
        let target = try makeSharedTexture(device: device, width: w, height: h)
        let key = FxShape.rounded(x: 4, y: 4, w: 56, h: 56, radius: 8)
        let vp = SIMD2<UInt32>(UInt32(w), UInt32(h))

        func lum(_ p: SIMD4<Float>) -> Float {
            0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
        }

        // 1. Plastic never paints past its coverage.
        for srgb in [false, true] {
            for roughness: Float in [0.0, 0.05, 0.45, 1.0] {
                for (col, intensity) in [(rgb(0xffffff), Float(1.0)), (rgb(0xffd60a), 1.0), (rgb(0xd7263d), 0.5), (rgb(0x202226), 1.0)] {
                    let p = PlasticParams(color: col, roughness: roughness)
                    for border: Float in [0.0, 6.0] {
                        let layer = Fx.fill(FillParams(.plastic(p), border: border, intensity: intensity)).on(key)
                        _ = try renderF16(renderer: renderer, queue: queue, target: target, viewport: vp, scale: 2.0, srgb: srgb, layers: [layer])
                        let img = readRGBA16Float(from: target)
                        let worst = img.map { max($0.x, max($0.y, $0.z)) - $0.w }.max() ?? 0
                        #expect(worst <= 2e-3, "srgb \(srgb) roughness \(roughness) rgb exceeded alpha by \(worst)")
                        if border == 0 {
                            let centre = img[(h / 2) * w + w / 2]
                            #expect(abs(centre.w - intensity) < 2e-3)
                        }
                    }
                }
            }
        }

        // 2. Highlight peak & spread order with roughness; lit top rim > shaded bottom rim.
        let base = rgb(0x3d6fd6)
        var peaks: [(peak: Float, spread: Int)] = []
        for roughness: Float in [0.05, 0.45, 1.0] {
            let p = PlasticParams(color: base, roughness: roughness)
            _ = try renderF16(renderer: renderer, queue: queue, target: target, viewport: vp, scale: 2.0, srgb: false, layers: [Fx.fill(FillParams(.plastic(p))).on(key)])
            let img = readRGBA16Float(from: target)
            let centre = img[(h / 2) * w + w / 2]
            #expect(abs(centre.x - base.r) < 0.07 && abs(centre.y - base.g) < 0.07 && abs(centre.z - base.b) < 0.07)
            let face = img.filter { $0.w > 0.999 }.map { lum($0) - lum(centre) }
            let peak = face.max() ?? 0
            let spread = face.filter { $0 > 0.5 * peak }.count
            let lit = lum(img[14 * w + 64])
            let shade = lum(img[114 * w + 64])
            #expect(lit > shade * 1.3, "roughness \(roughness): lit \(lit) vs shade \(shade)")
            peaks.append((peak, spread))
        }
        #expect(peaks[0].peak > peaks[1].peak && peaks[1].peak > peaks[2].peak)
        #expect(peaks[0].spread < peaks[2].spread)
    }

    @Test("Element-anchored liquid metal keys are pixel-for-pixel identical across offsets, scales, and isolated layers")
    func elementAnchoredMetalKeysAreIdentical() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        let renderer = try FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: false, srgbBlend: false))
        let w = 512
        let h = 64
        let target = try makeSharedTexture(device: device, width: w, height: h)

        func keysAt(anchor: FillAnchor, t: Float, ox: Float, oy: Float) -> [FxLayer] {
            (0..<8).map { k in
                Fx.fill(FillParams(.liquidMetal(LiquidMetalParams(anchor: anchor))))
                    .on(FxShape.rounded(x: ox + Float(k) * 28.0, y: oy, w: 24, h: 24, radius: 5))
                    .at(t)
            }
        }

        func tile(_ img: [UInt16], key k: Int, wPx: Int = 52, hPx: Int = 52, xBase: Int = 6, stridePx: Int = 56, yBase: Int = 6) -> [UInt16] {
            var out: [UInt16] = []
            out.reserveCapacity(wPx * hPx * 4)
            let x0 = xBase + stridePx * k
            for y in yBase..<(yBase + hPx) {
                for x in x0..<(x0 + wPx) {
                    let p = (y * w + x) * 4
                    out.append(contentsOf: img[p..<(p + 4)])
                }
            }
            return out
        }

        for t: Float in [1.3, 1e5 + 0.37] {
            let img = try renderF16(
                renderer: renderer, queue: queue, target: target,
                viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)), scale: 2.0, srgb: false,
                layers: keysAt(anchor: .element, t: t, ox: 4, oy: 4)
            )
            let first = tile(img, key: 0)
            #expect(first.indices.contains { $0 % 4 == 3 && f16ToF32(first[$0]) > 0.99 })
            for k in 1..<8 {
                #expect(tile(img, key: k) == first, "t = \(t): key \(k) differs from key 0")
            }

            let world = try renderF16(
                renderer: renderer, queue: queue, target: target,
                viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)), scale: 2.0, srgb: false,
                layers: keysAt(anchor: .world, t: t, ox: 4, oy: 4)
            )
            #expect((1..<8).contains { tile(world, key: $0) != tile(world, key: 0) })
        }

        // Subpixel offset + isolated layer origin shift match pixel-for-pixel.
        let subpx = try renderF16(
            renderer: renderer, queue: queue, target: target,
            viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)), scale: 2.0, srgb: false,
            layers: keysAt(anchor: .element, t: 1.3, ox: 4.25, oy: 4.375)
        )
        let sub0 = tile(subpx, key: 0, wPx: 53, hPx: 53)
        for k in 1..<8 {
            #expect(tile(subpx, key: k, wPx: 53, hPx: 53) == sub0)
        }

        let origin = SIMD2<Float>(16.0, 12.0)
        let inLayer = try renderF16(
            renderer: renderer, queue: queue, target: target,
            viewport: SIMD2<UInt32>(UInt32(w) + 16, UInt32(h) + 12), scale: 2.0, srgb: false,
            origin: origin,
            layers: keysAt(anchor: .element, t: 1.3, ox: 12.25, oy: 10.375)
        )
        for k in 0..<8 {
            #expect(tile(inLayer, key: k, wPx: 53, hPx: 53) == sub0, "in-layer origin shift: key \(k) differs")
        }

        // Non-power-of-two scale (1.5x).
        let scale15 = try renderF16(
            renderer: renderer, queue: queue, target: target,
            viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)), scale: 1.5, srgb: false,
            layers: keysAt(anchor: .element, t: 1.3, ox: 4, oy: 4)
        )
        let s15_0 = tile(scale15, key: 0, wPx: 40, hPx: 40, xBase: 4, stridePx: 42, yBase: 4)
        for k in 1..<8 {
            #expect(tile(scale15, key: k, wPx: 40, hPx: 40, xBase: 4, stridePx: 42, yBase: 4) == s15_0)
        }

        // Time folding at 512 s and 1024 s turns smoothly without a frame jump.
        let foldShape = FxShape.rounded(x: 4, y: 4, w: 24, h: 24, radius: 5)
        let dtFold: Float = 1.0 / 64.0
        for fold: Float in [512.0, 1024.0] {
            let before = try renderF16(
                renderer: renderer, queue: queue, target: target,
                viewport: SIMD2<UInt32>(128, 64), scale: 2.0, srgb: false,
                layers: [Fx.fill(FillParams(.liquidMetal(.chrome()))).on(foldShape).at(fold - dtFold)]
            )
            let atFold = try renderF16(
                renderer: renderer, queue: queue, target: target,
                viewport: SIMD2<UInt32>(128, 64), scale: 2.0, srgb: false,
                layers: [Fx.fill(FillParams(.liquidMetal(.chrome()))).on(foldShape).at(fold)]
            )
            let after = try renderF16(
                renderer: renderer, queue: queue, target: target,
                viewport: SIMD2<UInt32>(128, 64), scale: 2.0, srgb: false,
                layers: [Fx.fill(FillParams(.liquidMetal(.chrome()))).on(foldShape).at(fold + dtFold)]
            )
            #expect(before == after, "triangle wave is symmetric across \(fold)")
            let maxStep = zip(before, atFold).map { abs(f16ToF32($0) - f16ToF32($1)) }.max() ?? 0
            #expect(maxStep < 0.2, "no frame jump at \(fold): max step \(maxStep)")
        }
    }

    @Test("Simulated fire GPU 6-pass fluid solver runs 3 frames, stays finite, and advances flame")
    func simulatedFireGpuFramesAdvanceAndLightFlame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        let w = 64
        let h = 96
        let renderer = try FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: false, srgbBlend: false))
        renderer.setFireSim(true)
        let target = try makeSharedTexture(device: device, width: w, height: h)

        var frameWords: [[UInt16]] = []
        for n in 1...3 {
            let layer = Fx.fire(FireParams()).on(FxShape.rounded(x: 8, y: 60, w: 48, h: 24, radius: 6)).at(Float(n) * 0.05)
            _ = renderer.prepare(
                frame: FxFrame(viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)), scale: 1.0, layers: [layer])
            )
            #expect(renderer.simulatePending, "frame \(n) planned fire simulation steps")

            let cmd = try #require(queue.makeCommandBuffer())
            let stepped = try renderer.simulate(commandBuffer: cmd)
            #expect(stepped, "frame \(n) recorded compute simulation")

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.colorAttachments[0].storeAction = .store
            let pass = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
            try renderer.drawLayer(encoder: pass, layer: 0)
            pass.endEncoding()

            cmd.commit()
            cmd.waitUntilCompleted()
            #expect(cmd.status == .completed)

            let words = readRGBA16FloatWords(from: target)
            #expect(words.allSatisfy(isFiniteF16), "frame \(n) pixels are finite")
            let lit = stride(from: 3, to: words.count, by: 4).filter { words[$0] != 0 }.count
            #expect(lit > (w * h) / 20, "frame \(n) lit \(lit) pixels")
            frameWords.append(words)
        }
        #expect(frameWords[0] != frameWords[2], "simulation moved the flame")
    }

    @Test("Remaining shader pipelines (pulse, electric, distort, motion, extras) render finite GPU output")
    func remainingEffectShadersRenderFiniteNonZeroOutput() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        let renderer = try FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: false, srgbBlend: false))
        let w = 64
        let h = 64
        let target = try makeSharedTexture(device: device, width: w, height: h)
        let bd = try makeSharedTexture(device: device, width: w, height: h)
        let src = try makeSharedTexture(device: device, width: w, height: h)

        let clearCmd = try #require(queue.makeCommandBuffer())
        for (tex, col) in [(bd, MTLClearColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)),
                           (src, MTLClearColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))] {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = col
            rpd.colorAttachments[0].storeAction = .store
            clearCmd.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
        }
        clearCmd.commit()
        clearCmd.waitUntilCompleted()

        let box = FxShape.rounded(x: 12, y: 12, w: 40, h: 40, radius: 8)
        let vp = SIMD2<UInt32>(UInt32(w), UInt32(h))
        let motionSamples = MotionSamples.fromTrack(
            MotionBlurParams(mode: .directional, shutterAngle: 360.0, frameDt: 0.05, maxSamples: 8, pxPerSample: 1.0),
            rest: box.rect,
            at: 0.5,
            scale: 1.0
        ) { t in
            Pose(x: (t - 0.5) * 40.0)
        }
        let shutterSamples = MotionSamples.fromTrack(
            MotionBlurParams(mode: .shutter, shutterAngle: 360.0, frameDt: 0.05, maxSamples: 8, pxPerSample: 1.0),
            rest: box.rect,
            at: 0.5,
            scale: 1.0
        ) { t in
            Pose(x: (t - 0.5) * 40.0)
        }
        let effects: [FxLayer] = [
            Fx.pulse(PulseParams()).on(box).at(0.5),
            Fx.electric(ElectricParams(style: .border)).on(box).at(0.5),
            Fx.distort(.heatHaze(height: 16, scale: 20, speed: 1, amount: 4, wholeShape: true)).on(box).at(0.5),
            Fx.distort(.shockwave(at: SIMD2<Float>(32, 32), t0: 0.1)).on(box).at(0.4),
            Fx.distort(.lens(LensParams(frost: 0.5))).on(box).at(0.5),
            Fx.distort(.crt()).on(box).at(0.5),
            Fx.distort(.chromaSplit(offset: SIMD2<Float>(3, 0))).on(box).at(0.5),
            Fx.motionBlur(MotionBlurParams(), motionSamples).on(box).source(slot: 0, rect: box.rect).at(0.5),
            Fx.motionBlur(MotionBlurParams(), shutterSamples).on(box).source(slot: 0, rect: box.rect).at(0.5),
            Fx.shimmer(ShimmerParams()).on(box).at(0.5),
            Fx.sparkles(SparkleParams()).on(box).at(0.5),
            Fx.aurora(AuroraParams()).on(box).at(0.5),
            Fx.grain(GrainParams(amount: 0.2)).on(box).at(0.5),
        ]

        for (idx, layer) in effects.enumerated() {
            let words = try renderF16(
                renderer: renderer, queue: queue, target: target,
                viewport: vp, scale: 1.0, srgb: false,
                layers: [layer], backdrop: bd, sources: [src], blurFirst: true
            )
            #expect(words.allSatisfy(isFiniteF16), "effect \(idx) produced non-finite pixel")
            #expect(words.contains { $0 != 0 }, "effect \(idx) produced blank output")
        }
    }
    #endif
}
