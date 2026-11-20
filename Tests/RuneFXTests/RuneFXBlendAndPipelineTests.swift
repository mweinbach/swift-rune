import Foundation
import Testing
@testable import Rune
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

    @Test func offCenterFrostDoesNotReadThePreviousBlurOutsideItsScissor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb)
        let source = try makeTexture(device: device, width: 1, height: 1, format: .rgba16Float, usage: .shaderRead)
        let output = try makeTexture(device: device, width: 1280, height: 720, format: .rgba8Unorm_srgb)

        func render(_ shape: FxShape, backdrop: SIMD4<Float16>) throws {
            withUnsafeBytes(of: backdrop) { bytes in
                source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                               withBytes: bytes.baseAddress!, bytesPerRow: bytes.count)
            }
            let layer = Fx.lens(LensParams(frost: 1)).on(shape)
            fx.prepare(frame: FxFrame(viewport: SIMD2(1280, 720), scale: 2, layers: [layer], backdrop: source))
            let commands = try #require(queue.makeCommandBuffer())
            try #require(try fx.blurBackdrop(commandBuffer: commands, backdrop: source, layer: 0))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
            try fx.drawLayer(encoder: encoder, layer: 0)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            #expect(commands.status == .completed)
        }

        // Seed every mip with NaNs so a reused texture exposes out-of-scissor reads deterministically.
        try render(.rounded(x: 0, y: 0, w: 640, h: 360, radius: 0), backdrop: SIMD4(repeating: .nan))
        try render(.capsule(x: 388, y: 92, w: 220, h: 66), backdrop: SIMD4(1, 0, 0, 1))
        var pixel = SIMD4<UInt8>.zero
        output.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(992, 240, 1, 1), mipmapLevel: 0)
        #expect(pixel.x > 165 && pixel.y < 60 && pixel.z < 60 && pixel.w == 255)
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

    private func evalEmittedSwift(_ code: String) throws -> FillParams {
        struct ParseFailure: Error { let msg: String }

        func parseHex(_ token: String) throws -> UInt32 {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X"),
                  let val = UInt32(trimmed.dropFirst(2), radix: 16) else {
                throw ParseFailure(msg: "bad hex: \(trimmed)")
            }
            return val
        }

        func parseVec2(_ expr: String) throws -> SIMD2<Float> {
            let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("SIMD2<Float>("), trimmed.hasSuffix(")") else {
                throw ParseFailure(msg: "bad vec2: \(trimmed)")
            }
            let inner = String(trimmed.dropFirst("SIMD2<Float>(".count).dropLast())
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, let x = Float(parts[0]), let y = Float(parts[1]) else {
                throw ParseFailure(msg: "bad vec2 components: \(inner)")
            }
            return SIMD2<Float>(x, y)
        }

        func parseLiteral(_ lit: String, param: FxParam) throws -> FxValue {
            let s = lit.trimmingCharacters(in: .whitespacesAndNewlines)
            switch param.kind {
            case .number:
                guard let x = Float(s) else { throw ParseFailure(msg: "bad float: \(s)") }
                return .number(x)
            case .count:
                guard let n = UInt32(s) else { throw ParseFailure(msg: "bad count: \(s)") }
                return .count(n)
            case .toggle:
                if s == "true" { return .toggle(true) }
                if s == "false" { return .toggle(false) }
                throw ParseFailure(msg: "bad toggle: \(s)")
            case .choice(let choices):
                guard let idx = choices.firstIndex(where: { $0.swiftLiteral == s }) else {
                    throw ParseFailure(msg: "bad choice '\(s)' for \(param.id)")
                }
                return .choice(idx)
            case .color:
                guard s.hasPrefix("rgb("), s.hasSuffix(")") else {
                    throw ParseFailure(msg: "bad rgb: \(s)")
                }
                let inner = String(s.dropFirst(4).dropLast())
                return .color(rgb(try parseHex(inner)))
            case .colors:
                guard s.hasPrefix("Stops.hex(["), s.hasSuffix("])") else {
                    throw ParseFailure(msg: "bad Stops.hex: \(s)")
                }
                let inner = String(s.dropFirst("Stops.hex([".count).dropLast(2))
                let vals = try inner.split(separator: ",").map { try parseHex(String($0)) }
                return .colors(Stops.hex(vals))
            case .point:
                return .point(try parseVec2(s))
            case .points:
                guard s.hasPrefix("["), s.hasSuffix("]") else {
                    throw ParseFailure(msg: "bad points array: \(s)")
                }
                let inner = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.isEmpty { return .points([]) }
                var items: [SIMD2<Float>] = []
                var depth = 0
                var start = inner.startIndex
                for idx in inner.indices {
                    let ch = inner[idx]
                    if ch == "(" { depth += 1 }
                    else if ch == ")" { depth -= 1 }
                    else if ch == "," && depth == 0 {
                        items.append(try parseVec2(String(inner[start..<idx])))
                        start = inner.index(after: idx)
                    }
                }
                items.append(try parseVec2(String(inner[start..<inner.endIndex])))
                return .points(items)
            }
        }

        func paramId(fromSwiftField field: String) -> String {
            switch field {
            case "tintAmount": return "tint_amount"
            case "edgeColor": return "edge_color"
            case "rampAngle": return "ramp_angle"
            default: return field
            }
        }

        guard code.hasPrefix("Fx.fill("), code.hasSuffix(")") else {
            throw ParseFailure(msg: "missing Fx.fill wrapper: \(code)")
        }
        var body = String(code.dropFirst("Fx.fill(".count).dropLast())

        var intensity: Float = 1.0
        if let range = body.range(of: ").intensity(", options: .backwards) {
            let numStr = String(body[range.upperBound...].dropLast())
            guard let v = Float(numStr) else { throw ParseFailure(msg: "bad intensity: \(numStr)") }
            intensity = v
            body = String(body[..<range.lowerBound]) + ")"
        }

        var border: Float = 0.0
        if let range = body.range(of: ").border(", options: .backwards) {
            let numStr = String(body[range.upperBound...].dropLast())
            guard let v = Float(numStr) else { throw ParseFailure(msg: "bad border: \(numStr)") }
            border = v
            body = String(body[..<range.lowerBound]) + ")"
        }

        guard body.hasPrefix("FillParams("), body.hasSuffix(")") else {
            throw ParseFailure(msg: "missing FillParams wrapper: \(body)")
        }
        let inner = String(body.dropFirst("FillParams(".count).dropLast())
        guard let paren = inner.firstIndex(of: "("), inner.hasSuffix(")") else {
            throw ParseFailure(msg: "missing case paren: \(inner)")
        }
        let styleExpr = String(inner[inner.index(after: paren)..<inner.index(before: inner.endIndex)])

        var presetExpr = styleExpr
        var assignments: [(String, String)] = []
        if styleExpr.hasPrefix("{ var p = "), styleExpr.hasSuffix("; return p }()") {
            let stmts = String(styleExpr.dropFirst(2).dropLast(3))
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard stmts.count >= 2, stmts[0].hasPrefix("var p = "), stmts.last == "return p" else {
                throw ParseFailure(msg: "bad mutation closure: \(styleExpr)")
            }
            presetExpr = String(stmts[0].dropFirst("var p = ".count))
            for assign in stmts.dropFirst().dropLast() {
                guard assign.hasPrefix("p."),
                      let eq = assign.range(of: " = ") else {
                    throw ParseFailure(msg: "bad assignment: \(assign)")
                }
                let field = String(assign[assign.index(assign.startIndex, offsetBy: 2)..<eq.lowerBound])
                let rhs = String(assign[eq.upperBound...])
                assignments.append((field, rhs))
            }
        }

        var matchedInfo: FxStyleInfo?
        var matchedFill: FillParams?
        for info in fillStyles() {
            if let preset = info.presets.first(where: { $0.swiftCode == presetExpr }) {
                matchedInfo = info
                matchedFill = preset.fill()
                break
            }
        }
        guard let info = matchedInfo, var fill = matchedFill else {
            throw ParseFailure(msg: "unknown preset swiftCode: \(presetExpr)")
        }

        for (field, rhs) in assignments {
            let id = paramId(fromSwiftField: field)
            guard let param = info.params.first(where: { $0.id == id }) else {
                throw ParseFailure(msg: "unknown param \(id) on \(info.id)")
            }
            let val = try parseLiteral(rhs, param: param)
            guard fill.set(id, val) else {
                throw ParseFailure(msg: "failed to set \(id) on \(info.id)")
            }
        }

        return fill.border(border).intensity(intensity)
    }

    @Test func catalogToSwiftAndHexRoundTrip() throws {
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
            for (presetIndex, preset) in style.presets.enumerated() {
                let base = preset.fill()
                let baseCode = base.toSwift()
                #expect(try evalEmittedSwift(baseCode) == base)
                if presetIndex == 0 {
                    #expect(!baseCode.contains("{ var p = "))
                }

                // Single-field modification round-trip through emitted Swift for every param.
                var modifiedAll = base.border(3.5).intensity(0.75)
                for param in style.params {
                    let alt: FxValue
                    switch param.kind {
                    case .number(let minV, let maxV, _, _):
                        let cur: Float = {
                            if case .number(let x)? = base.get(param.id) { return x }
                            return minV
                        }()
                        let candidate = (minV + maxV) * 0.5 + 0.125
                        alt = .number(abs(candidate - cur) > 1e-4 ? candidate : minV)
                    case .count(let minC, let maxC):
                        let cur: UInt32 = {
                            if case .count(let n)? = base.get(param.id) { return n }
                            return minC
                        }()
                        alt = .count(cur != maxC ? maxC : minC)
                    case .toggle:
                        let cur = (base.get(param.id) == .toggle(true))
                        alt = .toggle(!cur)
                    case .choice(let choices):
                        let cur: Int = {
                            if case .choice(let k)? = base.get(param.id) { return k }
                            return 0
                        }()
                        alt = .choice((cur + 1) % choices.count)
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
                    var single = base
                    let okSingle = single.set(param.id, alt)
                    #expect(okSingle)
                    #expect(try evalEmittedSwift(single.toSwift()) == single, "\(style.id).\(param.id)")
                    let okAll = modifiedAll.set(param.id, alt)
                    #expect(okAll)
                }
                let emitted = modifiedAll.toSwift()
                #expect(try evalEmittedSwift(emitted) == modifiedAll, "\(style.id)/\(preset.id) all-modified round-trip")
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

    #if canImport(Metal)
    @Test func fxBlendModesOverCreamPaperAndFallbackWithoutBackdrop() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let warmGlow = Fx.glow(GlowParams(
            color: rgb(0xc85a14),
            core: rgb(0xe88c28),
            radius: 10.0,
            intensity: 1.15,
            inner: 0.8,
            hot: 0.35,
            reach: 2.5
        )).on(.rounded(x: 32, y: 32, w: 32, h: 32, radius: 10)).at(0.5)

        let creamSrgb = (Double(0xfa) / 255.0, Double(0xf7) / 255.0, Double(0xf2) / 255.0)
        let creamLin = (Double(srgbDecode(Float(creamSrgb.0))), Double(srgbDecode(Float(creamSrgb.1))), Double(srgbDecode(Float(creamSrgb.2))))

        for srgb in [false, true] {
            let format: MTLPixelFormat = srgb ? .rgba8Unorm : .rgba8Unorm_srgb
            let fx = try FxRenderer(device: device, pixelFormat: format)
            fx.setSrgbBlend(srgb)
            let clear: (Double, Double, Double, Double) = srgb
                ? (creamSrgb.0, creamSrgb.1, creamSrgb.2, 1.0)
                : (creamLin.0, creamLin.1, creamLin.2, 1.0)

            let bd = try makeTexture(device: device, width: 96, height: 96, format: format)
            let clearCmd = try #require(queue.makeCommandBuffer())
            let bdRpd = MTLRenderPassDescriptor()
            bdRpd.colorAttachments[0].texture = bd
            bdRpd.colorAttachments[0].loadAction = .clear
            bdRpd.colorAttachments[0].clearColor = MTLClearColor(red: clear.0, green: clear.1, blue: clear.2, alpha: 1.0)
            bdRpd.colorAttachments[0].storeAction = .store
            clearCmd.makeRenderCommandEncoder(descriptor: bdRpd)?.endEncoding()
            clearCmd.commit()
            clearCmd.waitUntilCompleted()

            let normal = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .normal, srgb: srgb, backdrop: bd)
            let multiply = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .multiply, srgb: srgb, backdrop: bd)
            let screen = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .screen, srgb: srgb, backdrop: bd)
            let overlay = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .overlay, srgb: srgb, backdrop: bd)
            let softLight = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .softLight, srgb: srgb, backdrop: bd)

            func px(_ buf: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
                let i = (y * 96 + x) * 4
                return [buf[i], buf[i + 1], buf[i + 2]]
            }

            for out in [normal, multiply, screen, overlay, softLight] {
                let corner = px(out, 2, 2)
                #expect(abs(Int(corner[0]) - 0xfa) <= 2 && abs(Int(corner[1]) - 0xf7) <= 2 && abs(Int(corner[2]) - 0xf2) <= 2)
            }

            let rimNorm = px(normal, 32, 48)
            let rimMul = px(multiply, 32, 48)
            let rimScr = px(screen, 32, 48)
            let rimOvl = px(overlay, 32, 48)
            let rimSoft = px(softLight, 32, 48)

            #expect(Int(rimMul[2]) + 40 < Int(rimNorm[2]) && Int(rimMul[1]) + 20 < Int(rimNorm[1]))
            #expect(rimMul[0] > rimMul[1] && rimMul[1] > rimMul[2])
            #expect(rimScr[0] >= 0xf8 && rimScr[1] >= rimMul[1] && rimScr[2] >= rimMul[2])
            #expect(rimOvl != rimNorm && rimSoft != rimNorm && rimOvl != rimSoft)

            let mulNoBd = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .multiply, srgb: srgb, backdrop: nil)
            let ovlNoBd = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .overlay, srgb: srgb, backdrop: nil)
            let softNoBd = try renderBlendCase(device: device, queue: queue, fx: fx, format: format, clear: clear, layers: [warmGlow], mode: .softLight, srgb: srgb, backdrop: nil)
            #expect(mulNoBd == normal)
            #expect(ovlNoBd == normal)
            #expect(softNoBd == normal)
        }
    }

    @Test func inLayerGlowGrainSlotScalePlasticAndBackdropParity() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        // 1. fills_match_across_blend_modes_when_opaque & plastic_matches_across_blend_modes
        let fxLin = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb)
        fxLin.setSrgbBlend(false)
        let fxGam = try FxRenderer(device: device, pixelFormat: .rgba8Unorm)
        fxGam.setSrgbBlend(true)

        let card = FxShape.rounded(x: 16, y: 16, w: 64, h: 64, radius: 0)
        let bgLin = Double(srgbDecode(32.0 / 255.0))
        for fillLayer in [
            Fx.fill(FillParams(.meshGradient(.dusk()))).on(card).at(0.5),
            Fx.fill(FillParams(.plastic(PlasticParams(color: rgb(0xffd60a), roughness: 0.45)))).on(card),
        ] {
            let lin = try renderBlendCase(device: device, queue: queue, fx: fxLin, format: .rgba8Unorm_srgb, clear: (bgLin, bgLin, bgLin, 1), layers: [fillLayer], mode: .normal, srgb: false, backdrop: nil)
            let gam = try renderBlendCase(device: device, queue: queue, fx: fxGam, format: .rgba8Unorm, clear: (32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 1), layers: [fillLayer], mode: .normal, srgb: true, backdrop: nil)
            let worst = zip(lin, gam).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 4)
        }

        // 2. faint_occlusion_keeps_the_glow_lit_in_gamma_blend
        let clearGlow = Fx.glow(GlowParams(color: rgb(0x4fc3ff), radius: 12, intensity: 1.0, occlusion: 0.0)).on(.rounded(x: 32, y: 32, w: 32, h: 32, radius: 8))
        let faintGlow = Fx.glow(GlowParams(color: rgb(0x4fc3ff), radius: 12, intensity: 1.0, occlusion: 0.002)).on(.rounded(x: 32, y: 32, w: 32, h: 32, radius: 8))
        let clearPx = try renderBlendCase(device: device, queue: queue, fx: fxGam, format: .rgba8Unorm, clear: (0, 0, 0, 1), layers: [clearGlow], mode: .normal, srgb: true, backdrop: nil)
        let faintPx = try renderBlendCase(device: device, queue: queue, fx: fxGam, format: .rgba8Unorm, clear: (0, 0, 0, 1), layers: [faintGlow], mode: .normal, srgb: true, backdrop: nil)
        var lit = 0
        for (x, y) in [(28, 48), (24, 48), (48, 27), (48, 22), (68, 48), (28, 28)] {
            let idx = (y * 96 + x) * 4
            if clearPx[idx] > 24 || clearPx[idx + 1] > 24 || clearPx[idx + 2] > 24 { lit += 1 }
            for c in 0..<3 {
                #expect(abs(Int(clearPx[idx + c]) - Int(faintPx[idx + c])) <= 6)
            }
        }
        #expect(lit >= 3)

        // 3. grain_is_symmetric_in_both_blend_modes
        let grain = Fx.grain(GrainParams(amount: 0.06)).on(.rounded(x: 0, y: 0, w: 96, h: 96, radius: 0))
        let grainZero = Fx.grain(GrainParams(amount: 0.0)).on(.rounded(x: 0, y: 0, w: 96, h: 96, radius: 0))
        for srgb in [false, true] {
            let fx = srgb ? fxGam : fxLin
            let fmt: MTLPixelFormat = srgb ? .rgba8Unorm : .rgba8Unorm_srgb
            let midLin = Double(srgbDecode(128.0 / 255.0))
            let midGam = 128.0 / 255.0
            let clear = srgb ? (midGam, midGam, midGam, 1.0) : (midLin, midLin, midLin, 1.0)
            let gImg = try renderBlendCase(device: device, queue: queue, fx: fx, format: fmt, clear: clear, layers: [grain], mode: .normal, srgb: srgb, backdrop: nil)
            let gBase = try renderBlendCase(device: device, queue: queue, fx: fx, format: fmt, clear: clear, layers: [grainZero], mode: .normal, srgb: srgb, backdrop: nil)
            var up = 0.0
            var down = 0.0
            var rawSum = 0.0
            for p in 0..<(96 * 96) {
                let rawV = Double(gImg[p * 4])
                let rawB = Double(gBase[p * 4])
                rawSum += rawV - rawB
                let v = srgb ? rawV / 255.0 : Double(srgbDecode(Float(rawV / 255.0)))
                let b = srgb ? rawB / 255.0 : Double(srgbDecode(Float(rawB / 255.0)))
                if v > b { up += (v - b) / max(1.0 - b, 1e-4) } else { down += (b - v) / max(b, 1e-4) }
            }
            let nPx = Double(96 * 96)
            up /= nPx
            down /= nPx
            #expect(up > 0.005 && down > 0.005, "srgb=\(srgb) up=\(up) down=\(down)")
            // Within 20%: NVIDIA quantizes the 8-bit source before the blend, which pulls odd grain steps half a
            // level down and leaves the two sides about 17% apart (a float blend leaves under 2%). The mean
            // shift below still holds the picture where it was.
            #expect(abs(up - down) <= 0.2 * (up + down) / 2.0, "srgb=\(srgb) asymmetric grain")
            if srgb {
                let rawMean = rawSum / nPx
                #expect(abs(rawMean) <= 1.0, "srgb grain shifted mean by \(rawMean)")
            }
        }

        // 4. slot_scale_scales_effect_lengths_and_radii_without_bleed
        let ring6 = Fx.fill(FillParams(.meshGradient(.dusk())).border(6.0)).on(.rounded(x: 8, y: 8, w: 32, h: 32, radius: 8))
        let ring12 = Fx.fill(FillParams(.meshGradient(.dusk())).border(12.0)).on(.rounded(x: 16, y: 16, w: 64, h: 64, radius: 16))
        let zoomedTarget = try makeTexture(device: device, width: 96, height: 96, format: .rgba8Unorm_srgb)
        fxLin.prepare(
            frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: [ring6]),
            slots: [FxSlot().scale(2.0)]
        )
        let cmdZ = try #require(queue.makeCommandBuffer())
        let rpdZ = MTLRenderPassDescriptor()
        rpdZ.colorAttachments[0].texture = zoomedTarget
        rpdZ.colorAttachments[0].loadAction = .clear
        rpdZ.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpdZ.colorAttachments[0].storeAction = .store
        let encZ = try #require(cmdZ.makeRenderCommandEncoder(descriptor: rpdZ))
        try fxLin.drawLayer(encoder: encZ, layer: 0)
        encZ.endEncoding()
        cmdZ.commit()
        cmdZ.waitUntilCompleted()
        let zoomed = readRGBA8(from: zoomedTarget)
        let direct = try renderBlendCase(device: device, queue: queue, fx: fxLin, format: .rgba8Unorm_srgb, clear: (0, 0, 0, 1), layers: [ring12], mode: .normal, srgb: false, backdrop: nil)
        let ringPxIdx = (48 * 96 + 22) * 4
        #expect(zoomed[ringPxIdx] > 40 || zoomed[ringPxIdx + 1] > 40 || zoomed[ringPxIdx + 2] > 40)
        let centerIdx = (48 * 96 + 48) * 4
        #expect(zoomed[centerIdx] == 0 && zoomed[centerIdx + 1] == 0 && zoomed[centerIdx + 2] == 0)
        let directRingIdx = (48 * 96 + 22) * 4
        #expect(abs(Int(zoomed[directRingIdx]) - Int(direct[directRingIdx])) <= 4)

        // 5. backdrop_slot_in_an_isolated_layer_reads_and_blurs_that_layers_target
        let isoTarget = try makeTexture(device: device, width: 96, height: 96, format: .rgba16Float)
        let isoBd = try makeTexture(device: device, width: 96, height: 96, format: .rgba16Float)
        let isoCmd = try #require(queue.makeCommandBuffer())
        // Left half bright cyan (0, 0.9, 1, 1), right half black (0, 0, 0, 1)
        var bdBytes = [UInt16](repeating: 0, count: 96 * 96 * 4)
        for y in 0..<96 {
            for x in 0..<96 {
                let idx = (y * 96 + x) * 4
                let cyan = x < 48
                bdBytes[idx + 0] = Float16(0.0).bitPattern
                bdBytes[idx + 1] = Float16(cyan ? 0.9 : 0.0).bitPattern
                bdBytes[idx + 2] = Float16(cyan ? 1.0 : 0.0).bitPattern
                bdBytes[idx + 3] = Float16(1.0).bitPattern
            }
        }
        bdBytes.withUnsafeBytes { raw in
            isoBd.replace(region: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 96 * 8)
        }
        let frostLayer = Fx.lens(LensParams(depth: 0.0, magnification: 1.0, frost: 0.85, shadow: 0.0, rim: 0.0)).on(.rounded(x: 16, y: 16, w: 64, h: 64, radius: 8))
        fxLin.addFormat(.rgba16Float)
        fxLin.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: [frostLayer], backdrop: isoBd))
        _ = try fxLin.blurBackdrop(commandBuffer: isoCmd, backdrop: isoBd, layer: 0)
        let isoRpd = MTLRenderPassDescriptor()
        isoRpd.colorAttachments[0].texture = isoTarget
        isoRpd.colorAttachments[0].loadAction = .clear
        isoRpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isoRpd.colorAttachments[0].storeAction = .store
        let isoEnc = try #require(isoCmd.makeRenderCommandEncoder(descriptor: isoRpd))
        try fxLin.drawLayer(encoder: isoEnc, format: .rgba16Float, origin: .zero, layer: 0)
        isoEnc.endEncoding()
        isoCmd.commit()
        isoCmd.waitUntilCompleted()
        #expect(isoCmd.status == .completed)
        var outWords = [UInt16](repeating: 0, count: 96 * 96 * 4)
        outWords.withUnsafeMutableBytes { raw in
            isoTarget.getBytes(raw.baseAddress!, bytesPerRow: 96 * 8, from: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0)
        }
        // Sample just to the right of x=48 at (52, 48): frosted lens blurs cyan from x<48 into x=52!
        let blurSampleG = Float(Float16(bitPattern: outWords[(48 * 96 + 52) * 4 + 1]))
        let blurSampleB = Float(Float16(bitPattern: outWords[(48 * 96 + 52) * 4 + 2]))
        #expect(blurSampleG > 0.05 && blurSampleB > 0.05)
    }

    @Test
    func inLayerClipFadeStackedGlassAndOriginParity() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb, options: FxOptions(dither: false, srgbBlend: false))
        fx.addFormat(.rgba16Float)

        // 1. fill_under_a_rounded_scroll_container_clips_without_a_layer & fill_in_a_faded_rounded_layer_matches_the_plain_fill_faded
        let orangeFill = Fx.fill(FillParams(.plastic(PlasticParams(color: rgb(0xeb6e28), roughness: 0.6))))
            .on(.rounded(x: 16, y: 16, w: 64, h: 64, radius: 0))
        let bottomFadeBits = UInt32(Float16(16.0).bitPattern) << 16
        let radius24Bits = Float(24.0).bitPattern
        let clipSlot = FxSlot().clip(
            SIMD4<Float>(16, 16, 80, 80),
            fade: SIMD4<UInt32>(0, bottomFadeBits, 0, radius24Bits)
        )
        for srgb in [false, true] {
            fx.setSrgbBlend(srgb)
            let fmt: MTLPixelFormat = srgb ? .rgba8Unorm : .rgba8Unorm_srgb
            let clearV = srgb ? Double(srgbEncode(0.125)) : 0.125
            let expectedBgByte = UInt8((srgbEncode(0.125) * 255.0).rounded())
            let plainOut = try renderBlendCase(device: device, queue: queue, fx: fx, format: fmt, clear: (clearV, clearV, clearV, 1), layers: [orangeFill], mode: .normal, srgb: srgb, backdrop: nil)
            let clippedTarget = try makeTexture(device: device, width: 96, height: 96, format: fmt)
            fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: [orangeFill]), slots: [clipSlot])
            let clipCmd = try #require(queue.makeCommandBuffer())
            let clipRpd = MTLRenderPassDescriptor()
            clipRpd.colorAttachments[0].texture = clippedTarget
            clipRpd.colorAttachments[0].loadAction = .clear
            clipRpd.colorAttachments[0].clearColor = MTLClearColor(red: clearV, green: clearV, blue: clearV, alpha: 1)
            clipRpd.colorAttachments[0].storeAction = .store
            let clipEnc = try #require(clipCmd.makeRenderCommandEncoder(descriptor: clipRpd))
            try fx.drawLayer(encoder: clipEnc, format: fmt, origin: .zero, layer: 0)
            clipEnc.endEncoding()
            clipCmd.commit()
            clipCmd.waitUntilCompleted()
            let clippedOut = readRGBA8(from: clippedTarget)
            let cornerIdx = (17 * 96 + 17) * 4
            #expect(abs(Int(clippedOut[cornerIdx]) - Int(expectedBgByte)) <= 6, "srgb=\(srgb)")
            let centerIdx = (48 * 96 + 48) * 4
            #expect(abs(Int(clippedOut[centerIdx]) - Int(plainOut[centerIdx])) <= 4, "srgb=\(srgb)")
            let midFadeIdx = (72 * 96 + 48) * 4
            #expect(clippedOut[midFadeIdx] < plainOut[midFadeIdx] - 15, "srgb=\(srgb)")
            #expect(clippedOut[midFadeIdx] > 40, "srgb=\(srgb)")
        }
        fx.setSrgbBlend(false)
        let cornerIdx = (17 * 96 + 17) * 4
        let centerIdx = (48 * 96 + 48) * 4

        let isoFillTarget = try makeTexture(device: device, width: 96, height: 96, format: .rgba16Float)
        fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: [orangeFill]), slots: [clipSlot])
        let isoCmd = try #require(queue.makeCommandBuffer())
        let isoRpd = MTLRenderPassDescriptor()
        isoRpd.colorAttachments[0].texture = isoFillTarget
        isoRpd.colorAttachments[0].loadAction = .clear
        isoRpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isoRpd.colorAttachments[0].storeAction = .store
        let isoEnc = try #require(isoCmd.makeRenderCommandEncoder(descriptor: isoRpd))
        try fx.drawLayer(encoder: isoEnc, format: .rgba16Float, origin: .zero, layer: 0)
        isoEnc.endEncoding()
        isoCmd.commit()
        isoCmd.waitUntilCompleted()
        var isoHalf = [UInt16](repeating: 0, count: 96 * 96 * 4)
        isoHalf.withUnsafeMutableBytes { raw in
            isoFillTarget.getBytes(raw.baseAddress!, bytesPerRow: 96 * 8, from: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0)
        }
        #expect(Float(Float16(bitPattern: isoHalf[cornerIdx + 3])) < 0.05)
        #expect(Float(Float16(bitPattern: isoHalf[centerIdx])) > 0.5)

        // 2. backdrop_slots_blur_background_and_stack_glass_over_glass_in_painter_order
        let sceneTex = try makeTexture(device: device, width: 96, height: 96, format: .rgba16Float)
        var sceneHalf = [UInt16](repeating: 0, count: 96 * 96 * 4)
        for y in 0..<96 {
            for x in 0..<96 {
                let idx = (y * 96 + x) * 4
                let cyan = x < 48
                sceneHalf[idx + 0] = Float16(0.0).bitPattern
                sceneHalf[idx + 1] = Float16(cyan ? 0.9 : 0.0).bitPattern
                sceneHalf[idx + 2] = Float16(cyan ? 1.0 : 0.0).bitPattern
                sceneHalf[idx + 3] = Float16(1.0).bitPattern
            }
        }
        sceneHalf.withUnsafeBytes { raw in
            sceneTex.replace(region: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 96 * 8)
        }
        let glass1 = Fx.lens(LensParams(depth: 0.0, magnification: 1.0, frost: 0.85, shadow: 0.0, rim: 0.0)).on(.rounded(x: 16, y: 16, w: 64, h: 64, radius: 8))
        let glass2 = Fx.fill(FillParams(.flutedGlass(FlutedGlassParams(refraction: 0.0, frost: 0.85, dispersion: 0.0, highlight: 0.0)))).on(.rounded(x: 24, y: 24, w: 56, h: 48, radius: 8))
        let outOne = try makeTexture(device: device, width: 96, height: 96, format: .rgba16Float)
        let cmdGlass = try #require(queue.makeCommandBuffer())
        fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: [glass1], backdrop: sceneTex))
        _ = try fx.blurBackdrop(commandBuffer: cmdGlass, backdrop: sceneTex, layer: 0)
        let rpdOne = MTLRenderPassDescriptor()
        rpdOne.colorAttachments[0].texture = outOne
        rpdOne.colorAttachments[0].loadAction = .clear
        rpdOne.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpdOne.colorAttachments[0].storeAction = .store
        let encOne = try #require(cmdGlass.makeRenderCommandEncoder(descriptor: rpdOne))
        try fx.drawLayer(encoder: encOne, format: .rgba16Float, origin: .zero, layer: 0)
        encOne.endEncoding()
        cmdGlass.commit()
        cmdGlass.waitUntilCompleted()
        var oneWords = [UInt16](repeating: 0, count: 96 * 96 * 4)
        oneWords.withUnsafeMutableBytes { raw in
            outOne.getBytes(raw.baseAddress!, bytesPerRow: 96 * 8, from: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0)
        }
        // Now paint an intermediate red bar into a copy of sceneTex (x = 40..<56, y = 32..<64) and stack glass2 on top
        var stackedBdWords = oneWords
        for y in 32..<64 {
            for x in 40..<56 {
                let idx = (y * 96 + x) * 4
                stackedBdWords[idx + 0] = Float16(1.0).bitPattern
                stackedBdWords[idx + 1] = Float16(0.1).bitPattern
                stackedBdWords[idx + 2] = Float16(0.2).bitPattern
                stackedBdWords[idx + 3] = Float16(1.0).bitPattern
            }
        }
        stackedBdWords.withUnsafeBytes { raw in
            sceneTex.replace(region: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 96 * 8)
        }
        let outTwo = try makeTexture(device: device, width: 96, height: 96, format: .rgba16Float)
        let cmdGlass2 = try #require(queue.makeCommandBuffer())
        fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: [glass2], backdrop: sceneTex))
        _ = try fx.blurBackdrop(commandBuffer: cmdGlass2, backdrop: sceneTex, layer: 0)
        let rpdTwo = MTLRenderPassDescriptor()
        rpdTwo.colorAttachments[0].texture = outTwo
        rpdTwo.colorAttachments[0].loadAction = .clear
        rpdTwo.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpdTwo.colorAttachments[0].storeAction = .store
        let encTwo = try #require(cmdGlass2.makeRenderCommandEncoder(descriptor: rpdTwo))
        try fx.drawLayer(encoder: encTwo, format: .rgba16Float, origin: .zero, layer: 0)
        encTwo.endEncoding()
        cmdGlass2.commit()
        cmdGlass2.waitUntilCompleted()
        var twoWords = [UInt16](repeating: 0, count: 96 * 96 * 4)
        twoWords.withUnsafeMutableBytes { raw in
            outTwo.getBytes(raw.baseAddress!, bytesPerRow: 96 * 8, from: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0)
        }
        let oneR60 = Float(Float16(bitPattern: oneWords[(48 * 96 + 60) * 4]))
        let twoR60 = Float(Float16(bitPattern: twoWords[(48 * 96 + 60) * 4]))
        #expect(twoR60 > oneR60 + 0.05)

        // End-to-end Runtime + MetalRenderer + FxRenderer check for:
        // (a) in_layer.rs:115-136 (`fill_in_a_faded_rounded_layer_matches_the_plain_fill_faded`: 0.5 * f + 0.5 * bg, layer format == rgba16Float)
        // (b) in_layer.rs:301-317 (`backdrop_slots_blur_background_and_stack_glass_over_glass_in_painter_order`: including post-glass green badge at (72, 64))
        struct EmptyS {}
        func renderRuntimeScene(
            srgb: Bool,
            formatsOut: inout [MTLPixelFormat],
            effectForMark: @escaping (UInt32) -> Fx,
            view: @escaping () -> El<EmptyS>
        ) throws -> Frame {
            let ui = try MetalRenderer(device: device)
            let fxComp = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb, options: FxOptions(dither: false, srgbBlend: srgb))
            fxComp.addFormat(.bgra8Unorm)
            fxComp.addFormat(.bgra8Unorm_srgb)
            fxComp.addFormat(.rgba16Float)
            fxComp.setSrgbBlend(srgb)

            let rt = Runtime<EmptyS>(state: EmptyS(), viewport: Vec2(96, 96), pixelScale: 1.0) { _, _ in view() }
            rt.setSrgbBlend(srgb)
            var seenFormats: [MTLPixelFormat] = []
            let out = try ui.renderOffscreen(rt.renderFrame(at: 0), backdropHook: { phase, site in
                let s = max(site.scale, 1.0)
                let shape = FxShape.rounded(
                    x: site.instance.rect.x / s,
                    y: site.instance.rect.y / s,
                    w: site.instance.rect.z / s,
                    h: site.instance.rect.w / s,
                    radius: site.instance.radii.x / s
                )
                let layer = effectForMark(site.mark).on(shape)
                let vp = SIMD2<UInt32>(
                    UInt32(max(0, Int(site.origin.x.rounded(.down)))) + UInt32(site.pixelSize.width),
                    UInt32(max(0, Int(site.origin.y.rounded(.down)))) + UInt32(site.pixelSize.height)
                )
                let slot = FxSlot(scale: s, clip: site.instance.clip, fade: site.instance.fade)
                switch phase {
                case .backdrop(let cb):
                    fxComp.prepare(frame: FxFrame(viewport: vp, scale: s, layers: [layer], backdrop: site.backdrop), slots: [slot])
                    if let bd = site.backdrop {
                        _ = try? fxComp.blurBackdrop(commandBuffer: cb, backdrop: bd, layer: 0)
                    }
                case .draw(let enc):
                    if site.inLayer { seenFormats.append(site.pixelFormat) }
                    if site.backdrop == nil {
                        fxComp.prepare(frame: FxFrame(viewport: vp, scale: s, layers: [layer]), slots: [slot])
                    }
                    try? fxComp.drawLayer(encoder: enc, format: site.pixelFormat, origin: site.origin, layer: 0)
                }
            })
            formatsOut = seenFormats
            return out
        }

        let duskFill = Fx.fill(FillParams(.meshGradient(.dusk())))
        for srgb in [false, true] {
            var plainFmts: [MTLPixelFormat] = []
            let plainImg = try renderRuntimeScene(srgb: srgb, formatsOut: &plainFmts, effectForMark: { _ in duskFill }) {
                el().size(96, 96).bg(Color.hex("#202020")!)
                    .child(el().absolute(x: 16, y: 16).size(64, 64).effect(1))
            }
            var layerFmts: [MTLPixelFormat] = []
            let layerImg = try renderRuntimeScene(srgb: srgb, formatsOut: &layerFmts, effectForMark: { _ in duskFill }) {
                el().size(96, 96).bg(Color.hex("#202020")!)
                    .child(
                        el().absolute(x: 16, y: 16).size(64, 64).opacity(0.5).clipRounded(24)
                            .child(el().absolute(x: 0, y: 0).size(64, 64).effect(1))
                            .child(el().absolute(x: 48, y: 48).size(8, 8).bg(Color.hex("#0000ff")!))
                    )
            }
            let bg: Float = 32.0 / 255.0
            for (x, y) in [(40, 40), (60, 30)] {
                let p = plainImg.pixel(x: x, y: y)
                let l = layerImg.pixel(x: x, y: y)
                let fillC: [Float] = [Float(p.x) / 255.0, Float(p.y) / 255.0, Float(p.z) / 255.0]
                let gotC: [UInt8] = [l.x, l.y, l.z]
                for c in 0..<3 {
                    let f = fillC[c]
                    let v = srgb ? (0.5 * f + 0.5 * bg) : srgbEncode(0.5 * srgbDecode(f) + 0.5 * srgbDecode(bg))
                    let want = UInt8((v * 255.0).rounded())
                    #expect(abs(Int(gotC[c]) - Int(want)) <= 4, "srgb=\(srgb) at (\(x),\(y)) c=\(c)")
                }
            }
            let cPx = layerImg.pixel(x: 17, y: 17)
            #expect(abs(Int(cPx.x) - 32) <= 2 && abs(Int(cPx.y) - 32) <= 2 && abs(Int(cPx.z) - 32) <= 2)
            #expect(layerFmts == [.rgba16Float])
        }

        let frostedFx: (UInt32) -> Fx = { mark in
            mark == 1 ? glass1.fx : glass2.fx
        }
        var dummyFmts: [MTLPixelFormat] = []
        let oneGlassImg = try renderRuntimeScene(srgb: false, formatsOut: &dummyFmts, effectForMark: frostedFx) {
            el().size(96, 96).bg(Color.hex("#202020")!)
                .child(el().absolute(x: 0, y: 0).size(48, 96).bg(Color.hex("#00e5ff")!))
                .child(el().absolute(x: 16, y: 16).size(64, 64).effect(1).effectBackdrop(true))
        }
        let pOne = oneGlassImg.pixel(x: 54, y: 48)
        #expect(pOne.y > 60 && pOne.z > 70)

        let stackedImg = try renderRuntimeScene(srgb: false, formatsOut: &dummyFmts, effectForMark: frostedFx) {
            el().size(96, 96).bg(Color.hex("#202020")!)
                .child(el().absolute(x: 0, y: 0).size(48, 96).bg(Color.hex("#00e5ff")!))
                .child(el().absolute(x: 16, y: 16).size(64, 64).effect(1).effectBackdrop(true))
                .child(el().absolute(x: 40, y: 32).size(16, 32).bg(Color.hex("#ff2040")!))
                .child(el().absolute(x: 24, y: 24).size(56, 48).effect(2).effectBackdrop(true))
                .child(el().absolute(x: 68, y: 60).size(10, 10).bg(Color.hex("#00ff00")!))
        }
        let pTwo = stackedImg.pixel(x: 60, y: 48)
        let pOne60 = oneGlassImg.pixel(x: 60, y: 48)
        #expect(Int(pTwo.x) > Int(pOne60.x) + 15)
        let badgePx = stackedImg.pixel(x: 72, y: 64)
        #expect(badgePx.x < 10 && badgePx.y > 245 && badgePx.z < 10)

        // 3. backdrop_origin_tracks_fractional_scale_scroll_live_offset_and_nested_layers + negative_layer_origins_copy_the_visible_region_at_all_window_edges
        let shiftedLayer = Fx.fill(FillParams(.plastic(PlasticParams(color: rgb(0x00e5ff), roughness: 0.5))))
            .on(.rounded(x: 20, y: 20, w: 32, h: 32, radius: 0))
        fx.prepare(frame: FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: [shiftedLayer]))
        let fracTarget = try makeTexture(device: device, width: 96, height: 96, format: .rgba8Unorm_srgb)
        let negTarget = try makeTexture(device: device, width: 96, height: 96, format: .rgba8Unorm_srgb)
        let cmdShift = try #require(queue.makeCommandBuffer())
        for (target, origin) in [(fracTarget, SIMD2<Float>(8.25, 8.75)), (negTarget, SIMD2<Float>(-8.25, -9.75))] {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            let enc = try #require(cmdShift.makeRenderCommandEncoder(descriptor: rpd))
            try fx.drawLayer(encoder: enc, format: .rgba8Unorm_srgb, origin: origin, layer: 0)
            enc.endEncoding()
        }
        cmdShift.commit()
        cmdShift.waitUntilCompleted()
        let fracPx = readRGBA8(from: fracTarget)
        let negPx = readRGBA8(from: negTarget)
        // Rect [20, 52) shifted by origin +8.25 lands at [11.75, 43.75) in texture space: (14, 14) is inside, (48, 48) is outside.
        #expect(fracPx[(14 * 96 + 14) * 4 + 2] > 200)
        #expect(fracPx[(48 * 96 + 48) * 4 + 2] < 10)
        // Rect [20, 52) shifted by origin -8.25,-9.75 lands at [28.25..60.25, 29.75..61.75): (56, 56) is inside, (24, 24) is outside.
        #expect(negPx[(56 * 96 + 56) * 4 + 2] > 200)
        #expect(negPx[(24 * 96 + 24) * 4 + 2] < 10)
    }

    @Test
    func srgbBlendDecodesBackdropWithoutDoubleEncodingOnFrameAndLayerTargets() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb, options: FxOptions(dither: false, srgbBlend: false))
        fx.addFormat(.rgba8Unorm)
        fx.addFormat(.rgba16Float)

        let clearGlass = Fx.fill(FillParams(.flutedGlass(FlutedGlassParams(refraction: 0, frost: 0, dispersion: 0, highlight: 0, tintAmount: 0))))
            .on(.rounded(x: 16, y: 16, w: 20, h: 64, radius: 0))
        let frostGlass = Fx.fill(FillParams(.flutedGlass(FlutedGlassParams(refraction: 0, frost: 0.6, dispersion: 0, highlight: 0, tintAmount: 0))))
            .on(.rounded(x: 36, y: 16, w: 20, h: 64, radius: 0))
        let ditherLayer = Fx.fill(FillParams(.dither(DitherParams.backdrop())))
            .on(.rounded(x: 56, y: 16, w: 24, h: 64, radius: 0))
        let layers = [clearGlass, frostGlass, ditherLayer]

        func runMidtone(format: MTLPixelFormat, srgb: Bool) throws -> [UInt8] {
            fx.setSrgbBlend(srgb)
            let bdTex = try makeTexture(device: device, width: 96, height: 96, format: format)
            let outTex = try makeTexture(device: device, width: 96, height: 96, format: format)
            let rVal = srgb ? Double(128.0 / 255.0) : Double(srgbDecode(128.0 / 255.0))
            let gVal = srgb ? Double(64.0 / 255.0) : Double(srgbDecode(64.0 / 255.0))
            let bVal = srgb ? Double(32.0 / 255.0) : Double(srgbDecode(32.0 / 255.0))
            let clearCol = MTLClearColor(red: rVal, green: gVal, blue: bVal, alpha: 1.0)

            let frame = FxFrame(viewport: SIMD2<UInt32>(96, 96), scale: 1.0, layers: layers, backdrop: bdTex)
            let slots = srgb ? Array(repeating: FxSlot().backdropSrgb(true), count: layers.count) : []
            _ = fx.prepare(frame: frame, slots: slots)

            let cmd = try #require(queue.makeCommandBuffer())
            let bdRpd = MTLRenderPassDescriptor()
            bdRpd.colorAttachments[0].texture = bdTex
            bdRpd.colorAttachments[0].loadAction = .clear
            bdRpd.colorAttachments[0].clearColor = clearCol
            bdRpd.colorAttachments[0].storeAction = .store
            let bdEnc = try #require(cmd.makeRenderCommandEncoder(descriptor: bdRpd))
            bdEnc.endEncoding()

            let outRpd = MTLRenderPassDescriptor()
            outRpd.colorAttachments[0].texture = outTex
            outRpd.colorAttachments[0].loadAction = .clear
            outRpd.colorAttachments[0].clearColor = clearCol
            outRpd.colorAttachments[0].storeAction = .store
            for i in 0..<layers.count {
                _ = try fx.blurBackdrop(commandBuffer: cmd, backdrop: bdTex, layer: i)
            }
            let outEnc = try #require(cmd.makeRenderCommandEncoder(descriptor: outRpd))
            for i in 0..<layers.count {
                try fx.drawLayer(encoder: outEnc, format: format, origin: .zero, layer: i)
            }
            outEnc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            if format == .rgba16Float {
                var words = [UInt16](repeating: 0, count: 96 * 96 * 4)
                words.withUnsafeMutableBytes { raw in
                    outTex.getBytes(raw.baseAddress!, bytesPerRow: 96 * 8, from: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0)
                }
                return words.map { UInt8(min(max((Float(Float16(bitPattern: $0)) * 255.0).rounded(), 0), 255)) }
            }
            return readRGBA8(from: outTex)
        }

        let lin = try runMidtone(format: .rgba8Unorm_srgb, srgb: false)
        let gam = try runMidtone(format: .rgba8Unorm, srgb: true)
        let clearIdx = (48 * 96 + 24) * 4
        #expect(abs(Int(lin[clearIdx + 0]) - 128) <= 3 && abs(Int(lin[clearIdx + 1]) - 64) <= 3 && abs(Int(lin[clearIdx + 2]) - 32) <= 3)
        #expect(abs(Int(gam[clearIdx + 0]) - 128) <= 3 && abs(Int(gam[clearIdx + 1]) - 64) <= 3 && abs(Int(gam[clearIdx + 2]) - 32) <= 3)

        let frostIdx = (48 * 96 + 46) * 4
        for c in 0..<3 {
            #expect(abs(Int(lin[frostIdx + c]) - Int(gam[frostIdx + c])) <= 3)
        }

        var ditherDiff = 0
        for y in 24..<72 {
            for x in 60..<76 {
                let idx = (y * 96 + x) * 4
                let diff = abs(Int(lin[idx + 0]) - Int(gam[idx + 0]))
                    + abs(Int(lin[idx + 1]) - Int(gam[idx + 1]))
                    + abs(Int(lin[idx + 2]) - Int(gam[idx + 2]))
                ditherDiff = max(ditherDiff, diff)
            }
        }
        #expect(ditherDiff <= 6)

        let layerGam = try runMidtone(format: .rgba16Float, srgb: true)
        for c in 0..<3 {
            #expect(abs(Int(layerGam[clearIdx + c]) - [128, 64, 32][c]) <= 3)
        }
        #expect(layerGam[frostIdx + 0] < 135 && layerGam[frostIdx + 1] < 70)
    }
    #endif
}
