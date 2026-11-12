import Foundation
import Testing
@testable import RuneFX

#if canImport(Metal)
import Metal
#endif

private func srgbDecode(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
}

private func srgbEncode(_ c: Float) -> Float {
    let x = min(max(c, 0.0), 1.0)
    return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1.0 / 2.4) - 0.055
}

private enum RefSeparable {
    case multiply
    case screen
    case overlay
    case softLight
}

private func refComposite(_ mode: RefSeparable, src: SIMD4<Float>, dst: SIMD4<Float>) -> SIMD4<Float> {
    let sa = src.w
    let da = dst.w
    var out = SIMD4<Float>.zero
    for c in 0..<3 {
        let s = sa > 0 ? src[c] / sa : 0
        let b = da > 0 ? dst[c] / da : 0
        let blended: Float
        switch mode {
        case .multiply:
            blended = b * s
        case .screen:
            blended = b + s - b * s
        case .overlay:
            blended = b <= 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s)
        case .softLight:
            if s <= 0.5 {
                blended = b - (1 - 2 * s) * b * (1 - b)
            } else {
                let d: Float = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : sqrtf(b)
                blended = b + (2 * s - 1) * (d - b)
            }
        }
        out[c] = src[c] * (1 - da) + sa * da * blended + dst[c] * (1 - sa)
    }
    out.w = sa + da * (1 - sa)
    return out
}

@Suite("RuneFX Blend, Clip & Pipeline Parity Tests")
struct RuneFXBlendAndPipelineTests {
    #if canImport(Metal)
    private func makeTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        format: MTLPixelFormat,
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

    private func readRGBA8(from tex: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
        tex.getBytes(&bytes, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        return bytes
    }

    private func renderBlendCase(
        device: MTLDevice,
        queue: MTLCommandQueue,
        fx: FxRenderer,
        format: MTLPixelFormat,
        clear: (Double, Double, Double, Double),
        layers: [FxLayer],
        mode: FxBlend,
        srgb: Bool,
        backdrop: MTLTexture?
    ) throws -> [UInt8] {
        let target = try makeTexture(device: device, width: 96, height: 96, format: format)
        let slots = layers.isEmpty ? [] : [FxSlot().blend(mode).backdropSrgb(srgb)]
        fx.prepare(
            frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: layers, backdrop: backdrop, sources: []),
            slots: slots
        )
        let cmd = try #require(queue.makeCommandBuffer())
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: clear.0, green: clear.1, blue: clear.2, alpha: clear.3)
        rpd.colorAttachments[0].storeAction = .store
        let pass = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
        try fx.drawAll(encoder: pass, layers: layers, place: nil)
        pass.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return readRGBA8(from: target)
    }

    @Test func softGlowCoverageMatchesReferenceBlendingInBothSpaces() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let modes: [(FxBlend, RefSeparable)] = [
            (.multiply, .multiply),
            (.screen, .screen),
            (.overlay, .overlay),
            (.softLight, .softLight),
        ]

        for srgb in [false, true] {
            let format: MTLPixelFormat = srgb ? .rgba8Unorm : .rgba8Unorm_srgb
            let fx = try FxRenderer(device: device, pixelFormat: format, options: FxOptions(dither: false, srgbBlend: srgb))
            fx.setSrgbBlend(srgb)

            func decodePixel(_ slice: ArraySlice<UInt8>) -> SIMD4<Float> {
                let base = slice.startIndex
                let r = Float(slice[base]) / 255.0
                let g = Float(slice[base + 1]) / 255.0
                let b = Float(slice[base + 2]) / 255.0
                let a = Float(slice[base + 3]) / 255.0
                return SIMD4<Float>(
                    srgb ? r : srgbDecode(r),
                    srgb ? g : srgbDecode(g),
                    srgb ? b : srgbDecode(b),
                    a
                )
            }

            for opacity: Float in [0.35, 1.0] {
                let layers = [
                    Fx.glow(GlowParams(
                        color: rgb(0xc85a14),
                        core: rgb(0xe88c28),
                        radius: 10.0,
                        intensity: 0.8,
                        occlusion: 1.0,
                        reach: 2.5
                    ))
                    .on(.rounded(x: 32, y: 32, w: 32, h: 32, radius: 10))
                    .at(0.5)
                    .opacity(opacity)
                ]

                let source = try renderBlendCase(
                    device: device,
                    queue: queue,
                    fx: fx,
                    format: format,
                    clear: (0, 0, 0, 0),
                    layers: layers,
                    mode: .normal,
                    srgb: srgb,
                    backdrop: nil
                )

                let backdropConfigs: [([Float], Float)] = [
                    ([0.98, 0.97, 0.95], 1.0),
                    ([0.3, 0.6, 0.8], 1.0),
                    ([0.3, 0.6, 0.8], 0.35),
                    ([0.0, 0.0, 0.0], 0.0),
                ]

                for (rgbVals, alpha) in backdropConfigs {
                    let c0 = (srgb ? Double(rgbVals[0]) : Double(srgbDecode(rgbVals[0]))) * Double(alpha)
                    let c1 = (srgb ? Double(rgbVals[1]) : Double(srgbDecode(rgbVals[1]))) * Double(alpha)
                    let c2 = (srgb ? Double(rgbVals[2]) : Double(srgbDecode(rgbVals[2]))) * Double(alpha)
                    let clear = (c0, c1, c2, Double(alpha))

                    let backdrop = try makeTexture(device: device, width: 96, height: 96, format: format, usage: [.shaderRead])
                    let bytes = try renderBlendCase(
                        device: device,
                        queue: queue,
                        fx: fx,
                        format: format,
                        clear: clear,
                        layers: [],
                        mode: .normal,
                        srgb: srgb,
                        backdrop: nil
                    )
                    bytes.withUnsafeBytes { raw in
                        if let ptr = raw.baseAddress {
                            backdrop.replace(
                                region: MTLRegionMake2D(0, 0, 96, 96),
                                mipmapLevel: 0,
                                withBytes: ptr,
                                bytesPerRow: 96 * 4
                            )
                        }
                    }

                    for (mode, oracle) in modes {
                        let actual = try renderBlendCase(
                            device: device,
                            queue: queue,
                            fx: fx,
                            format: format,
                            clear: clear,
                            layers: layers,
                            mode: mode,
                            srgb: srgb,
                            backdrop: backdrop
                        )

                        var partial = 0
                        for pxIndex in 0..<(96 * 96) {
                            let off = pxIndex * 4
                            let src = decodePixel(source[off..<(off + 4)])
                            if src.w > 0.02 && src.w < 0.3 { partial += 1 }
                            let dst = decodePixel(bytes[off..<(off + 4)])
                            let want = refComposite(oracle, src: src, dst: dst)
                            for c in 0..<4 {
                                let v = (c < 3 && !srgb) ? srgbEncode(want[c]) : want[c]
                                let wantByte = UInt8(min(max((v * 255.0).rounded(), 0.0), 255.0))
                                let gotByte = actual[off + c]
                                let diff = abs(Int(gotByte) - Int(wantByte))
                                #expect(diff <= 3, "\(mode) srgb=\(srgb) opacity=\(opacity) alpha=\(alpha) ch=\(c): \(gotByte) vs \(wantByte)")
                            }
                        }
                        #expect(partial > 100, "exercise soft edges, not just opaque centres")
                    }
                }
            }
        }
    }

    @Test func pipelinesAreBuiltLazilyForWhatFramesDraw() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let window: MTLPixelFormat = .rgba8Unorm_srgb
        let layerFmt: MTLPixelFormat = .rgba16Float
        let fx = try FxRenderer(device: device, pixelFormat: window)
        fx.addFormat(layerFmt)
        #expect(fx.builtPipelines == 0, "nothing is built before a frame draws")

        func draw(_ format: MTLPixelFormat, _ layers: [FxLayer], _ slots: [FxSlot]) throws {
            let target = try makeTexture(device: device, width: 64, height: 64, format: format)
            fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(64, 64), scale: 1.0, layers: layers), slots: slots)
            let cmd = try #require(queue.makeCommandBuffer())
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.colorAttachments[0].storeAction = .store
            let pass = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
            for i in 0..<layers.count {
                try fx.drawLayer(encoder: pass, format: format, origin: .zero, layer: i)
            }
            pass.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        let shape = FxShape.rounded(x: 16, y: 16, w: 32, h: 32, radius: 6)
        let glow = Fx.glow(GlowParams()).on(shape)
        try draw(window, [glow], [])
        #expect(fx.builtPipelines == 1, "a glow builds the glow")
        try draw(window, [glow], [])
        #expect(fx.builtPipelines == 1, "and keeps it")

        let fire = Fx.fire(FireParams()).on(shape)
        try draw(window, [glow, fire, glow], [FxSlot(), FxSlot(), FxSlot().blend(.screen)])
        #expect(fx.builtPipelines == 3, "a fire and a screen-blended glow build one each")

        try draw(layerFmt, [glow], [])
        #expect(fx.builtPipelines == 4, "another format builds its own when drawn into")

        try fx.buildEveryPipeline()
        #expect(fx.builtPipelines == 32, "eight families, two blends, two formats")
    }

    @Test func steadyFrameReusesResourceHandlesAndBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb)
        let bd = try makeTexture(device: device, width: 96, height: 96, format: .rgba8Unorm_srgb)
        let slotBd = try makeTexture(device: device, width: 96, height: 96, format: .rgba8Unorm_srgb)

        let layers = [
            Fx.glow(GlowParams(radius: 10.0, intensity: 0.8)).on(.rounded(x: 16, y: 16, w: 32, h: 32, radius: 8)).at(0.5),
            Fx.lens(LensParams(frost: 0.6)).on(.rounded(x: 40, y: 40, w: 40, h: 40, radius: 12)).at(0.5),
        ]

        func runFrame(backdrop: MTLTexture, slotBackdrop: MTLTexture?) throws -> [UInt64?] {
            fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: layers, backdrop: backdrop))
            let cmd = try #require(queue.makeCommandBuffer())
            if let slotBackdrop {
                _ = try fx.blurBackdrop(commandBuffer: cmd, backdrop: slotBackdrop, layer: 1)
            }
            cmd.commit()
            cmd.waitUntilCompleted()
            return (0..<layers.count).map { fx.layerResourceHandle($0) }
        }

        let first = try runFrame(backdrop: bd, slotBackdrop: nil)
        let bufs1 = fx.bufferIdentities
        let second = try runFrame(backdrop: bd, slotBackdrop: nil)
        let bufs2 = fx.bufferIdentities
        #expect(first.allSatisfy { $0 != nil })
        #expect(first == second, "steady frame resource handles are reused")
        #expect(bufs1.insts == bufs2.insts && bufs1.tables == bufs2.tables, "GPU buffers are reused")

        let slot1 = try runFrame(backdrop: bd, slotBackdrop: slotBd)
        let slot2 = try runFrame(backdrop: bd, slotBackdrop: slotBd)
        #expect(slot1 == slot2, "slot backdrop handle is reused")

        let other = try makeTexture(device: device, width: 96, height: 96, format: .rgba8Unorm_srgb)
        let third = try runFrame(backdrop: other, slotBackdrop: nil)
        #expect(third[0] == second[0])
        #expect(third[1] != second[1])
    }

    @Test func linearBackdropViewsNotDoubleDecodedInSrgbFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm)
        fx.setSrgbBlend(true)
        let layers = [Fx.distort(.chromaSplit(offset: SIMD2<Float>(1e-6, 0.0))).on(.rounded(x: 0, y: 0, w: 32, h: 32, radius: 0))]

        for format in [MTLPixelFormat.rgba8Unorm_srgb, .rgba16Float] {
            let bdTex = try makeTexture(device: device, width: 32, height: 32, format: format)
            for perSlot in [false, true] {
                let target = try makeTexture(device: device, width: 32, height: 32, format: .rgba8Unorm)
                let frame = FxFrame(
                    viewport: SIMD2<UInt32>(32, 32),
                    scale: 1.0,
                    layers: layers,
                    backdrop: perSlot ? nil : bdTex
                )
                let slots = perSlot ? [FxSlot().backdropSrgb(false)] : []
                let graph = fx.prepare(frame: frame, slots: slots)
                #expect(graph.stats.drawn == 1)

                let cmd = try #require(queue.makeCommandBuffer())
                let bdPassDesc = MTLRenderPassDescriptor()
                bdPassDesc.colorAttachments[0].texture = bdTex
                bdPassDesc.colorAttachments[0].loadAction = .clear
                bdPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.25, green: 0.125, blue: 0.0625, alpha: 1.0)
                bdPassDesc.colorAttachments[0].storeAction = .store
                let bdEnc = try #require(cmd.makeRenderCommandEncoder(descriptor: bdPassDesc))
                bdEnc.endEncoding()

                _ = try fx.blurBackdrop(commandBuffer: cmd, backdrop: bdTex, layer: 0)

                let drawDesc = MTLRenderPassDescriptor()
                drawDesc.colorAttachments[0].texture = target
                drawDesc.colorAttachments[0].loadAction = .clear
                drawDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                drawDesc.colorAttachments[0].storeAction = .store
                let drawEnc = try #require(cmd.makeRenderCommandEncoder(descriptor: drawDesc))
                try fx.drawLayer(encoder: drawEnc, layer: 0)
                drawEnc.endEncoding()

                cmd.commit()
                cmd.waitUntilCompleted()

                let pixels = readRGBA8(from: target)
                let at = (16 * 32 + 16) * 4
                let expected: [UInt8] = [0.25, 0.125, 0.0625].map { UInt8((srgbEncode($0) * 255.0).rounded()) }
                for c in 0..<3 {
                    let diff = abs(Int(pixels[at + c]) - Int(expected[c]))
                    #expect(diff <= 2, "\(format) perSlot=\(perSlot) ch=\(c): \(pixels[at + c]) != \(expected[c])")
                }
            }
        }
    }

    @Test func clipAlphaRoundedAndSoftEdgeFadeOnGpu() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm)
        let target = try makeTexture(device: device, width: 64, height: 64, format: .rgba8Unorm)
        let layer = Fx.fill(FillParams(.plastic(.glossy()))).on(.rounded(x: 0, y: 0, w: 64, h: 64, radius: 0))

        // Circular clip radius 16 inside (8, 8, 56, 56), soft left fade = 8pt (f16)
        let fadeWord = UInt32(Float16(8.0).bitPattern)
        let radiusBits = Float(16.0).bitPattern
        let slot = FxSlot().clip(SIMD4<Float>(8, 8, 56, 56), fade: SIMD4<UInt32>(fadeWord, 0, 0, radiusBits))

        fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(64, 64), scale: 1.0, layers: [layer]), slots: [slot])
        let cmd = try #require(queue.makeCommandBuffer())
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        let pass = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
        try fx.drawLayer(encoder: pass, layer: 0)
        pass.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let px = readRGBA8(from: target)
        func alphaAt(_ x: Int, _ y: Int) -> UInt8 { px[(y * 64 + x) * 4 + 3] }

        // Outside clip rect and rounded corner (9, 9) is cut by circular radius 16!
        #expect(alphaAt(4, 32) == 0, "outside clip rect")
        #expect(alphaAt(9, 9) == 0, "corner clipped by rounded clip radius")
        // Near left fade edge (10, 32) is partially faded vs centre (32, 32) opaque.
        #expect(alphaAt(10, 32) > 0 && alphaAt(10, 32) < 160, "soft left fade active")
        #expect(alphaAt(32, 32) >= 250, "centre fully opaque")
    }
    #endif

    @Test func catalogToSwiftAndHexRoundTrip() {
        for hex in [UInt32(0x000000), 0xffffff, 0xf3c56b, 0x0b3d5c, 0x808080] {
            #expect(rgb(hex).hex() == hex)
        }

        let gold = FillParams(.liquidMetal(.gold()))
        #expect(gold.toSwift() == "Fx.fill(FillParams(.liquidMetal(LiquidMetalParams.gold())))")

        var roseMod = LiquidMetalParams.rose()
        roseMod.flow = 0.8
        let f = FillParams(.liquidMetal(roseMod)).border(4.0)
        #expect(f.toSwift() == "Fx.fill(FillParams(.liquidMetal({ var p = LiquidMetalParams.rose(); p.flow = 0.8; return p }())).border(4.0))")

        for style in fillStyles() {
            for preset in style.presets {
                let base = preset.fill()
                #expect(base.toSwift() == "Fx.fill(FillParams(\(base.toSwift().dropFirst("Fx.fill(FillParams(".count).dropLast(2))))")
                var modified = base.border(3.5).intensity(0.75)
                for param in style.params {
                    let alt: FxValue
                    switch param.kind {
                    case .number(let minV, let maxV, _, _):
                        alt = .number((minV + maxV) * 0.5 + 0.125)
                    case .count(_, let maxC):
                        alt = .count(maxC)
                    case .toggle:
                        let cur = (base.get(param.id) == .toggle(true))
                        alt = .toggle(!cur)
                    case .choice(let choices):
                        alt = .choice(choices.count - 1)
                    case .color:
                        alt = .color(rgb(0xabcdef))
                    case .colors(let minS, _):
                        let palette: [UInt32] = [0x102030, 0x405060, 0x708090, 0xa0b0c0, 0xd0e0f0, 0x112233]
                        alt = .colors(Stops.hex(Array(palette.prefix(minS))))
                    case .point:
                        alt = .point(SIMD2<Float>(0.3, 0.7))
                    case .points:
                        alt = .points(Array(repeating: SIMD2<Float>(0.25, 0.75), count: maxStops))
                    }
                    let didSet = modified.set(param.id, alt)
                    #expect(didSet)
                }
                let emitted = modified.toSwift()
                #expect(emitted.contains(".border(3.5)"))
                #expect(emitted.contains(".intensity(0.75)"))
            }
        }
    }

    @Test func clipBoundsTightenGraphQuads() {
        let card = FxShape.rounded(x: 10, y: 10, w: 80, h: 80, radius: 8)
        let layer = Fx.fill(FillParams(.plastic(.glossy()))).on(card)
        let outsideSlot = FxSlot().clip(SIMD4<Float>(200, 200, 300, 300))
        let graph = FxRenderPassGraph.build(
            viewport: SIMD2<UInt32>(400, 400),
            scale: 1.0,
            layers: [layer],
            slots: [outsideSlot]
        )
        #expect(graph.stats.culledOffscreen == 1)
        #expect(graph.stats.drawn == 0)
    }
}
