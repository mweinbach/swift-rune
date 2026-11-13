#if canImport(Metal)
import Metal
#endif
import Rune
import Testing
@testable import RuneLight

@Suite("RuneLight Parity Tests")
struct RuneLightParityTests {
    @Test("Metal uniform and buffer struct strides match shader layouts")
    func uniformStructStridesMatchShaders() {
        #expect(MemoryLayout<Prim>.stride == 96)
        #expect(MemoryLayout<Light>.stride == 64)
        #expect(MemoryLayout<LightFrameUniforms>.stride == 144)
        #expect(MemoryLayout<CascadeUniforms>.stride == 16)
        #expect(MemoryLayout<Glass>.stride == 96)
        #expect(MemoryLayout<GlassLight>.stride == 32)
        #expect(MemoryLayout<GlassUniforms>.stride == 48)
    }

    @Test func primFromRuneConversionsMapGeometryAndRadii() {
        let motionRect = MotionRect(left: 10, top: 20, right: 130, bottom: 80)
        let corners = Corners(4, 8, 12, 16)
        let p1 = Prim.fromRune(rect: motionRect, corners: corners, scale: 2.0)
        #expect(p1.rect == SIMD4<Float>(20, 40, 240, 120))
        #expect(p1.radii == SIMD4<Float>(8, 16, 24, 32))

        let layout = ComputedLayout(localRect: MotionRect(left: 5, top: 15, right: 85, bottom: 55))
        let p2 = Prim.fromRune(layout: layout, corners: .all(6), scale: 1.0)
        #expect(p2.rect == SIMD4<Float>(5, 15, 80, 40))
        #expect(p2.radii == SIMD4<Float>(6, 6, 6, 6))

        struct Dummy {}
        let el: El<Dummy> = El<Dummy>().rounded(10)
        let p3 = Prim.fromRune(element: el, rect: motionRect, scale: 1.0)
        #expect(p3.rect == SIMD4<Float>(10, 20, 120, 60))
        #expect(p3.radii == SIMD4<Float>(10, 10, 10, 10))
    }

    #if canImport(Metal)
    private func makeTexture(
        device: MTLDevice,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        storageMode: MTLStorageMode = .shared,
        usage: MTLTextureUsage = [.shaderRead, .renderTarget]
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = storageMode
        return try #require(device.makeTexture(descriptor: desc))
    }

    private func clearTexture(
        queue: MTLCommandQueue,
        tex: MTLTexture,
        color: MTLClearColor
    ) throws {
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
    }

    private func readRGBA8(from tex: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            tex.getBytes(
                raw.baseAddress!,
                bytesPerRow: tex.width * 4,
                from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func readRGBA16Float(from tex: MTLTexture) -> [SIMD4<Float>] {
        var words = [UInt16](repeating: 0, count: tex.width * tex.height * 4)
        words.withUnsafeMutableBytes { raw in
            tex.getBytes(
                raw.baseAddress!,
                bytesPerRow: tex.width * 8,
                from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                mipmapLevel: 0
            )
        }
        func toF32(_ h: UInt16) -> Float {
            let s = UInt32(h >> 15)
            let e = Int((h >> 10) & 0x1f)
            let m = Float(h & 0x3ff)
            let v: Float
            switch e {
            case 0: v = m * powf(2.0, -24.0)
            case 31: v = m == 0 ? .infinity : .nan
            default: v = (1.0 + m / 1024.0) * powf(2.0, Float(e - 15))
            }
            return s == 1 ? -v : v
        }
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(tex.width * tex.height)
        for i in stride(from: 0, to: words.count, by: 4) {
            out.append(SIMD4<Float>(toF32(words[i]), toF32(words[i + 1]), toF32(words[i + 2]), toF32(words[i + 3])))
        }
        return out
    }

    private func makePrims(_ n: Int) -> [Prim] {
        (0..<n).map { i in
            Prim.rect(Float(i % 16) * 14.0, Float(i / 16) * 8.0, 10.0, 6.0).raised(4.0)
        }
    }

    @Test("Growing prim buffer preserves visibility target and lazy GI allocation matches targets.rs")
    func rendererVisibilityInspectAndTimings() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let w = 256
        let h = 160
        let renderer = try LightRenderer(device: device, width: UInt32(w), height: UInt32(h), outputFormat: .rgba8Unorm)
        #expect(renderer.visibilityTexture.width == 128)
        #expect(renderer.visibilityTexture.height == 80)

        let baseTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let textTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let targetTex = try makeTexture(device: device, format: .rgba8Unorm, width: w, height: h)
        try clearTexture(queue: queue, tex: baseTex, color: MTLClearColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1))
        try clearTexture(queue: queue, tex: textTex, color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))

        // Growing the prim buffer preserves the render targets.
        do {
            let cmd = try #require(queue.makeCommandBuffer())
            let scene = LightScene(prims: makePrims(8), lights: [Light.point(60, 40, 120)])
            #expect(renderer.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: targetTex))
            cmd.commit()
            cmd.waitUntilCompleted()
            #expect(cmd.status == .completed)
        }
        let visBefore = renderer.visibilityTexture
        do {
            let cmd = try #require(queue.makeCommandBuffer())
            let scene = LightScene(prims: makePrims(300), lights: [Light.point(60, 40, 120)])
            #expect(renderer.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: targetTex))
            cmd.commit()
            cmd.waitUntilCompleted()
            #expect(cmd.status == .completed)
        }
        #expect(renderer.visibilityTexture === visBefore)

        // Without GI, nothing GI is allocated or recorded.
        let insOff = renderer.inspect()
        #expect(insOff.emission === insOff.fluence)
        #expect(insOff.merged[0] === insOff.fluence)
        #expect(renderer.computePasses == 2)

        // Turning GI on allocates its targets and records scene + 5 cascades + fluence.
        let cmdGI = try #require(queue.makeCommandBuffer())
        let giScene = LightScene(
            prims: makePrims(8),
            lights: [Light.point(60, 40, 120)],
            settings: LightSettings(gi: GIParams())
        )
        #expect(renderer.render(scene: giScene, commandBuffer: cmdGI, baseTexture: baseTex, textTexture: textTex, targetTexture: targetTex))
        cmdGI.commit()
        cmdGI.waitUntilCompleted()
        #expect(cmdGI.status == .completed)

        let insOn = renderer.inspect()
        #expect(insOn.field.width == 128)
        #expect(insOn.emission !== insOn.fluence)
        #expect(insOn.emission.width == insOn.giSize.0)
        #expect(insOn.occluders.width == insOn.giSize.0)
        #expect(insOn.fluence.width == insOn.giSize.0)
        #expect(insOn.merged.count == Int(lightCascades))
        #expect(insOn.own.count == Int(lightCascades))
        #expect(renderer.computePasses == 2 + 2 + lightCascades)

        let timings = try #require(renderer.readTimings(commandBuffer: cmdGI))
        #expect(timings.total >= 0)
        #expect(timings.raster >= 0)
    }

    @Test("Torch beam profile focuses spotlight cone in composite pass")
    func torchBeamFocusesConeAndRollsOffSpill() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let w = 160
        let h = 160
        let renderer = try LightRenderer(device: device, width: UInt32(w), height: UInt32(h), outputFormat: .rgba16Float)
        let baseTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let textTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let targetTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        try clearTexture(queue: queue, tex: baseTex, color: MTLClearColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        try clearTexture(queue: queue, tex: textTex, color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))

        // Torch straight down onto (40, 80) with narrow cone (halfAngle = 0.25 rad).
        let torch = Light.point(40, 80, 100)
            .intensity(2.0)
            .spot(axis: SIMD3<Float>(0, 0, -1), halfAngle: 0.25)
        let settings = LightSettings(ambient: .zero, contactAO: 0, rim: 0)
        let scene = LightScene(prims: [Prim.rect(0, 0, Float(w), Float(h))], lights: [torch], settings: settings)

        let cmd = try #require(queue.makeCommandBuffer())
        #expect(renderer.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: targetTex))
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)

        let img = readRGBA16Float(from: targetTex)
        for p in img {
            #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite)
        }
        let centerLit = img[80 * w + 40]
        let outsideCone = img[80 * w + 140]
        #expect(centerLit.x > 0.2, "torch core should illuminate (40, 80), got \(centerLit)")
        #expect(centerLit.x > outsideCone.x * 5.0, "torch beam core \(centerLit.x) should strongly exceed off-cone \(outsideCone.x)")
    }

    @Test("GI cascades propagate emissive prims and LightScene.emission into composite")
    func giEmissiveAndExtraEmissionLightNeighbors() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let w = 128
        let h = 128
        let renderer = try LightRenderer(device: device, width: UInt32(w), height: UInt32(h), outputFormat: .rgba16Float)
        renderer.inspectCascades = true

        let baseTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let textTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let extraEmitTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let targetTex = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        try clearTexture(queue: queue, tex: baseTex, color: MTLClearColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        try clearTexture(queue: queue, tex: textTex, color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        try clearTexture(queue: queue, tex: extraEmitTex, color: MTLClearColor(red: 0.5, green: 1.5, blue: 2.0, alpha: 1))

        let emitter = Prim.rect(16, 48, 24, 32).emissive(SIMD3<Float>(4.0, 1.5, 0.4))
        let hint = Prim.rect(80, 48, 24, 32).giHint()
        let settings = LightSettings(ambient: .zero, gi: GIParams(strength: 2.0, air: 0.2, bounce: 0.0, absorption: 0.35, emission: 1.0))
        let scene = LightScene(prims: [emitter, hint], lights: [], settings: settings, emission: extraEmitTex)

        let cmd = try #require(queue.makeCommandBuffer())
        #expect(renderer.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: targetTex))
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)

        let img = readRGBA16Float(from: targetTex)
        for p in img {
            #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite)
        }
        // Neighbor pixels beside the emitter should receive non-zero warm GI light.
        let nearEmitter = img[64 * w + 52]
        #expect(nearEmitter.x > 0.02 && nearEmitter.y > 0.01, "expected warm GI glow near emitter, got \(nearEmitter)")
        #expect(renderer.computePasses == 2 + 2 + lightCascades + 1)
    }

    @Test("GlassRenderer.render builds frost pyramid, refracts with dispersion, and casts shadow")
    func glassRendererRefractsWithFrostAndShadow() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let w = 160
        let h = 160
        let glass = try GlassRenderer(device: device, width: UInt32(w), height: UInt32(h), pixelFormat: .rgba16Float)
        #expect(glass.mips >= 4)

        let backdrop = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let fluence = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)
        let target = try makeTexture(device: device, format: .rgba16Float, width: w, height: h)

        // Striped / gradient backdrop in shared storage so we verify refraction + frost change pixels.
        var bdPixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let stripe: Float = ((x / 8) % 2 == 0) ? 0.8 : 0.2
                bdPixels[idx + 0] = stripe
                bdPixels[idx + 1] = Float(y) / Float(h) * 0.7 + 0.1
                bdPixels[idx + 2] = 0.4
                bdPixels[idx + 3] = 1.0
            }
        }
        let bdWords: [UInt16] = bdPixels.map { Float16($0).bitPattern }
        bdWords.withUnsafeBytes { raw in
            backdrop.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 8)
        }
        try clearTexture(queue: queue, tex: fluence, color: MTLClearColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))

        let slab = Glass.rounded(40, 40, 80, 80, radius: 16)
            .thickness(32)
            .bevel(20)
            .gap(12)
            .dome(6)
            .frost(0.4)
            .dispersion(0.03)
        let light = GlassLight(pos: SIMD4<Float>(60, 20, 180, 60), color: SIMD4<Float>(1.5, 1.3, 1.0, 0))

        let cmd = try #require(queue.makeCommandBuffer())
        try glass.render(
            commandBuffer: cmd,
            glass: [slab],
            lights: [light],
            settings: GlassSettings(),
            backdrop: backdrop,
            fluence: fluence,
            target: target
        )
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.status == .completed)

        let out = readRGBA16Float(from: target)
        for p in out {
            #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite)
        }
        // Outside glass, unaffected far corner matches backdrop closely.
        let farCorner = out[4 * w + 4]
        #expect(abs(farCorner.x - 0.8) < 0.05)
        // Under offset drop shadow (near bottom of slab), backdrop is darkened.
        let underShadow = out[132 * w + 88]
        let unshadowed = bdPixels[(132 * w + 88) * 4]
        #expect(underShadow.x < unshadowed * 0.9, "expected drop shadow darkening: \(underShadow.x) vs \(unshadowed)")
        // Inside bevel/glass center, color is non-zero and shifted by refraction/highlight/tint.
        let inside = out[80 * w + 80]
        #expect(inside.x > 0.01 && inside.y > 0.01)
    }

    @Test("Steady frames reuse render targets, uniform buffers, and glass pyramid without allocation")
    func steadyFrameReusesTargetsAndBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let renderer = try LightRenderer(device: device, width: 64, height: 64, outputFormat: .rgba16Float)
        let baseTex = try makeTexture(device: device, format: .rgba16Float, width: 64, height: 64)
        let textTex = try makeTexture(device: device, format: .rgba16Float, width: 64, height: 64)
        let target = try makeTexture(device: device, format: .rgba16Float, width: 64, height: 64)
        let scene = LightScene(
            prims: [Prim.rect(16, 16, 24, 24).raised(8).emissive(SIMD3<Float>(0.5, 0.3, 0.2))],
            lights: [Light.point(48, 32, 32).color(SIMD3<Float>(1.0, 0.8, 0.6)).intensity(1.5)],
            settings: LightSettings(gi: GIParams())
        )

        let cmd1 = try #require(queue.makeCommandBuffer())
        #expect(renderer.render(scene: scene, commandBuffer: cmd1, baseTexture: baseTex, textTexture: textTex, targetTexture: target))
        cmd1.commit()
        cmd1.waitUntilCompleted()
        let ids1 = renderer.resourceIdentities
        let inspect1 = renderer.inspect()

        let cmd2 = try #require(queue.makeCommandBuffer())
        #expect(renderer.render(scene: scene, commandBuffer: cmd2, baseTexture: baseTex, textTexture: textTex, targetTexture: target))
        cmd2.commit()
        cmd2.waitUntilCompleted()
        let ids2 = renderer.resourceIdentities
        let inspect2 = renderer.inspect()

        #expect(ids1 == ids2)
        #expect(inspect1.fluence === inspect2.fluence)
        #expect(inspect1.emission === inspect2.emission)
        #expect(inspect1.occluders === inspect2.occluders)

        let glass = try GlassRenderer(device: device, width: 64, height: 64, pixelFormat: .rgba16Float)
        let bd = try makeTexture(device: device, format: .rgba16Float, width: 64, height: 64)
        let fluence = try makeTexture(device: device, format: .rgba16Float, width: 64, height: 64)
        let g1 = try #require(queue.makeCommandBuffer())
        try glass.render(commandBuffer: g1, glass: [Glass.rounded(8, 8, 48, 48, radius: 8)], lights: [], settings: GlassSettings(), backdrop: bd, fluence: fluence, target: target)
        g1.commit()
        g1.waitUntilCompleted()
        let gIds1 = glass.resourceIdentities

        let g2 = try #require(queue.makeCommandBuffer())
        try glass.render(commandBuffer: g2, glass: [Glass.rounded(8, 8, 48, 48, radius: 8)], lights: [], settings: GlassSettings(), backdrop: bd, fluence: fluence, target: target)
        g2.commit()
        g2.waitUntilCompleted()
        let gIds2 = glass.resourceIdentities
        #expect(gIds1 == gIds2)
    }
    #endif
}
