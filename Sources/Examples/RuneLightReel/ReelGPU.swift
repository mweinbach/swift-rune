import Foundation
import Rune
import RuneFX
import RuneLight

#if canImport(Metal)
import Metal
#endif

#if canImport(Metal)
func reelMakeTexture(
    device: MTLDevice,
    label: String,
    width: Int,
    height: Int,
    mips: Int = 1,
    format: MTLPixelFormat = .rgba16Float,
    usage: MTLTextureUsage = [.renderTarget, .shaderRead],
    storageMode: MTLStorageMode = .private
) -> MTLTexture {
    let td = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format,
        width: max(width, 1),
        height: max(height, 1),
        mipmapped: mips > 1
    )
    td.mipmapLevelCount = mips
    td.usage = usage
    td.storageMode = storageMode
    let t = device.makeTexture(descriptor: td)!
    t.label = label
    return t
}

struct ReelLayer {
    let tex: MTLTexture
    let mips: [MTLTexture]

    init(device: MTLDevice, label: String) {
        let tex = reelMakeTexture(
            device: device,
            label: label,
            width: reelW,
            height: reelH,
            mips: reelMips,
            format: .rgba16Float,
            usage: [.renderTarget, .shaderRead],
            storageMode: .private
        )
        self.tex = tex
        self.mips = (0..<reelMips).map { m in
            tex.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2D, levels: m..<(m + 1), slices: 0..<1)!
        }
    }
}

struct ReelViz {
    let gBuffer: MTLBuffer
    let vpBuffer: MTLBuffer
    let field: MTLRenderPipelineState
    let scene: MTLRenderPipelineState
    let cascade: MTLRenderPipelineState
    let fluence: MTLRenderPipelineState
    let mip: MTLRenderPipelineState
    let layer: MTLRenderPipelineState
    let accum: MTLRenderPipelineState
    let mean: MTLComputePipelineState
    let meanUniforms: [ReelMeanU]
    let meansOwn: [MTLTexture]
    let meansMrg: [MTLTexture]
    let linSampler: MTLSamplerState
    let anisoSampler: MTLSamplerState
    let dummy: MTLTexture

    init(device: MTLDevice, gs: (UInt32, UInt32)) throws {
        precondition(MemoryLayout<ReelGU>.stride == 64)
        precondition(MemoryLayout<ReelVP>.stride == 112)
        precondition(MemoryLayout<ReelMeanU>.stride == 16)

        let vizLib = try device.makeLibrary(source: ReelShaders.vizMetalSource, options: nil)
        let meanLib = try device.makeLibrary(source: ReelShaders.meanMetalSource, options: nil)

        func makePipe(vs: String, fs: String, blendMode: String?) throws -> MTLRenderPipelineState {
            let pd = MTLRenderPipelineDescriptor()
            pd.label = fs
            pd.vertexFunction = vizLib.makeFunction(name: vs)
            pd.fragmentFunction = vizLib.makeFunction(name: fs)
            let att = pd.colorAttachments[0]!
            att.pixelFormat = .rgba16Float
            if let blendMode {
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                if blendMode == "add" {
                    att.sourceRGBBlendFactor = .one
                    att.destinationRGBBlendFactor = .one
                    att.sourceAlphaBlendFactor = .one
                    att.destinationAlphaBlendFactor = .one
                } else {
                    att.sourceRGBBlendFactor = .one
                    att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    att.sourceAlphaBlendFactor = .one
                    att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: pd)
        }

        self.field = try makePipe(vs: "vs_full", fs: "fs_field", blendMode: nil)
        self.scene = try makePipe(vs: "vs_full", fs: "fs_scene", blendMode: nil)
        self.cascade = try makePipe(vs: "vs_full", fs: "fs_cascade", blendMode: nil)
        self.fluence = try makePipe(vs: "vs_full", fs: "fs_fluence", blendMode: nil)
        self.mip = try makePipe(vs: "vs_full", fs: "fs_mip", blendMode: nil)
        self.layer = try makePipe(vs: "vs_layer", fs: "fs_layer", blendMode: "premul")
        self.accum = try makePipe(vs: "vs_full", fs: "fs_accum", blendMode: "add")

        let meanFn = meanLib.makeFunction(name: "cs_mean")!
        self.mean = try device.makeComputePipelineState(function: meanFn)

        self.meanUniforms = (0..<lightCascades).map { ReelMeanU(n: $0) }
        self.meansOwn = (0..<Int(lightCascades)).map { n in
            reelMakeTexture(
                device: device,
                label: "mean_own_\(n)",
                width: Int(gs.0 >> n),
                height: Int(gs.1 >> n),
                mips: 1,
                format: .rgba16Float,
                usage: [.shaderWrite, .shaderRead],
                storageMode: .private
            )
        }
        self.meansMrg = (0..<Int(lightCascades)).map { n in
            reelMakeTexture(
                device: device,
                label: "mean_mrg_\(n)",
                width: Int(gs.0 >> n),
                height: Int(gs.1 >> n),
                mips: 1,
                format: .rgba16Float,
                usage: [.shaderWrite, .shaderRead],
                storageMode: .private
            )
        }

        let linDesc = MTLSamplerDescriptor()
        linDesc.minFilter = .linear
        linDesc.magFilter = .linear
        linDesc.sAddressMode = .clampToEdge
        linDesc.tAddressMode = .clampToEdge
        self.linSampler = device.makeSamplerState(descriptor: linDesc)!

        let anisoDesc = MTLSamplerDescriptor()
        anisoDesc.minFilter = .linear
        anisoDesc.magFilter = .linear
        anisoDesc.mipFilter = .linear
        anisoDesc.maxAnisotropy = 16
        anisoDesc.sAddressMode = .clampToEdge
        anisoDesc.tAddressMode = .clampToEdge
        self.anisoSampler = device.makeSamplerState(descriptor: anisoDesc)!

        self.gBuffer = device.makeBuffer(length: MemoryLayout<ReelGU>.stride, options: .storageModeShared)!
        self.vpBuffer = device.makeBuffer(length: reelMaxVP * MemoryLayout<ReelVP>.stride, options: .storageModeShared)!
        self.dummy = reelMakeTexture(device: device, label: "dummy", width: 1, height: 1, usage: [.shaderRead], storageMode: .private)
    }
}

struct ReelBloom {
    let levels: [MTLTexture]
    let down: MTLRenderPipelineState
    let up: MTLRenderPipelineState
    let sampler: MTLSamplerState

    init(device: MTLDevice) throws {
        precondition(MemoryLayout<ReelBloomU>.stride == 16)
        let lib = try device.makeLibrary(source: ReelShaders.bloomMetalSource, options: nil)

        func makePipe(fs: String, additive: Bool) throws -> MTLRenderPipelineState {
            let pd = MTLRenderPipelineDescriptor()
            pd.label = fs
            pd.vertexFunction = lib.makeFunction(name: "vs_b")
            pd.fragmentFunction = lib.makeFunction(name: fs)
            let att = pd.colorAttachments[0]!
            att.pixelFormat = .rgba16Float
            if additive {
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: pd)
        }

        self.down = try makePipe(fs: "fs_bdown", additive: false)
        self.up = try makePipe(fs: "fs_bup", additive: true)

        let tex = reelMakeTexture(
            device: device,
            label: "bloom",
            width: reelW / 2,
            height: reelH / 2,
            mips: reelBloomLevels,
            format: .rgba16Float,
            usage: [.renderTarget, .shaderRead],
            storageMode: .private
        )
        self.levels = (0..<reelBloomLevels).map { m in
            tex.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2D, levels: m..<(m + 1), slices: 0..<1)!
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sd)!
    }
}

struct ReelEnc {
    let yuv: MTLComputePipelineState
    let rgba: MTLComputePipelineState
    let noise: MTLTexture
    let y8: MTLBuffer
    let y10: MTLBuffer
    let rgbaBuf: MTLBuffer

    init(device: MTLDevice) throws {
        precondition(MemoryLayout<ReelEncU>.stride == 32)
        let lib = try device.makeLibrary(source: ReelShaders.encMetalSource, options: nil)
        self.yuv = try device.makeComputePipelineState(function: lib.makeFunction(name: "cs_yuv")!)
        self.rgba = try device.makeComputePipelineState(function: lib.makeFunction(name: "cs_rgba")!)

        let noise = reelMakeTexture(
            device: device,
            label: "blue_noise",
            width: 64,
            height: 64,
            mips: 1,
            format: .rgba8Unorm,
            usage: [.shaderRead],
            storageMode: .shared
        )
        let bn = blueNoise()
        bn.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                noise.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: ptr, bytesPerRow: 256)
            }
        }
        self.noise = noise

        let n = reelW * reelH
        self.y8 = device.makeBuffer(length: n * 3 / 2, options: .storageModeShared)!
        self.y10 = device.makeBuffer(length: n * 3, options: .storageModeShared)!
        self.rgbaBuf = device.makeBuffer(length: n * 4, options: .storageModeShared)!
    }
}

final class ReelUIRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    private var atlasTex: MTLTexture
    private var atlasGen: UInt64 = 0
    private var instBuf: MTLBuffer
    private var instCap: Int

    init(device: MTLDevice) throws {
        precondition(MemoryLayout<ReelUIInst>.stride == 112)
        self.device = device
        let lib = try device.makeLibrary(source: ReelShaders.uiMetalSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "reel ui"
        pd.vertexFunction = lib.makeFunction(name: "reel_ui_vs")
        pd.fragmentFunction = lib.makeFunction(name: "reel_ui_fs")
        let att = pd.colorAttachments[0]!
        att.pixelFormat = .rgba16Float
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .one
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: pd)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sd)!

        self.atlasTex = reelMakeTexture(
            device: device,
            label: "reel ui atlas",
            width: 1024,
            height: 1024,
            mips: 1,
            format: .r8Unorm,
            usage: [.shaderRead],
            storageMode: .shared
        )
        self.instCap = 2048
        self.instBuf = device.makeBuffer(length: instCap * MemoryLayout<ReelUIInst>.stride, options: .storageModeShared)!
    }

    private func syncAtlas(_ glyphAtlas: GlyphAtlas) {
        let r8 = glyphAtlas.atlas
        if atlasTex.width != r8.width || atlasTex.height != r8.height {
            atlasTex = reelMakeTexture(
                device: device,
                label: "reel ui atlas",
                width: r8.width,
                height: r8.height,
                mips: 1,
                format: .r8Unorm,
                usage: [.shaderRead],
                storageMode: .shared
            )
            atlasGen = 0
        }
        if atlasGen != glyphAtlas.generation {
            r8.texels.withUnsafeBytes { raw in
                if let ptr = raw.baseAddress {
                    atlasTex.replace(
                        region: MTLRegionMake2D(0, 0, r8.width, r8.height),
                        mipmapLevel: 0,
                        withBytes: ptr,
                        bytesPerRow: r8.width
                    )
                }
            }
            atlasGen = glyphAtlas.generation
        }
    }

    func draw(commandBuffer: MTLCommandBuffer, target: MTLTexture, clear: MTLClearColor, insts: [ReelUIInst], glyphAtlas: GlyphAtlas) {
        syncAtlas(glyphAtlas)
        if insts.count > instCap {
            var nextCap = instCap
            while nextCap < insts.count { nextCap *= 2 }
            instCap = nextCap
            instBuf = device.makeBuffer(length: instCap * MemoryLayout<ReelUIInst>.stride, options: .storageModeShared)!
        }
        if !insts.isEmpty {
            _ = insts.withUnsafeBytes { raw in
                memcpy(instBuf.contents(), raw.baseAddress!, raw.count)
            }
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = clear
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        if !insts.isEmpty {
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(instBuf, offset: 0, index: 0)
            enc.setFragmentBuffer(instBuf, offset: 0, index: 0)
            enc.setFragmentTexture(atlasTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: insts.count)
        }
        enc.endEncoding()
    }
}

let reelMaxVP = 64

/// 64×64 blue noise, three independent channels (void and cluster, Ulichney 1993).
func blueNoise() -> [UInt8] {
    let n = 64
    let sigma: Float = 1.9
    var kernel = [Float](repeating: 0.0, count: n * n)
    for y in 0..<n {
        for x in 0..<n {
            let dx = Float(min(x, n - x))
            let dy = Float(min(y, n - y))
            kernel[y * n + x] = exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma))
        }
    }
    var out = [UInt8](repeating: 255, count: n * n * 4)
    var seed: UInt32 = 0x9e3779b9
    func rnd() -> UInt32 {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return seed
    }

    for ch in 0..<3 {
        var on = [Bool](repeating: false, count: n * n)
        var energy = [Float](repeating: 0.0, count: n * n)
        func toggle(_ i: Int, _ add: Bool) {
            on[i] = add
            let ix = i % n
            let iy = i / n
            let s: Float = add ? 1.0 : -1.0
            for y in 0..<n {
                let ky = (y + n - iy) % n
                for x in 0..<n {
                    let kx = (x + n - ix) % n
                    energy[y * n + x] += s * kernel[ky * n + kx]
                }
            }
        }
        let ones = (n * n) / 10
        var placed = 0
        while placed < ones {
            let i = Int(rnd()) % (n * n)
            if !on[i] {
                toggle(i, true)
                placed += 1
            }
        }
        func tightest() -> Int {
            var best = -1
            var bestVal: Float = -.greatestFiniteMagnitude
            for i in 0..<(n * n) where on[i] {
                if energy[i] > bestVal {
                    bestVal = energy[i]
                    best = i
                }
            }
            return best
        }
        func voidest() -> Int {
            var best = -1
            var bestVal: Float = .greatestFiniteMagnitude
            for i in 0..<(n * n) where !on[i] {
                if energy[i] < bestVal {
                    bestVal = energy[i]
                    best = i
                }
            }
            return best
        }
        while true {
            let c = tightest()
            toggle(c, false)
            let v = voidest()
            toggle(v, true)
            if v == c { break }
        }
        var rank = [Int](repeating: 0, count: n * n)
        let protoOn = on
        let protoE = energy
        for r in (0..<ones).reversed() {
            let c = tightest()
            toggle(c, false)
            rank[c] = r
        }
        on = protoOn
        energy = protoE
        for r in ones..<(n * n) {
            let v = voidest()
            toggle(v, true)
            rank[v] = r
        }
        for i in 0..<(n * n) {
            out[i * 4 + ch] = UInt8(((Float(rank[i]) + 0.5) / Float(n * n) * 255.0).rounded())
        }
    }
    return out
}

final class ReelCtx {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let ui: ReelUIRenderer
    let ts: TextSystem
    let light: LightRenderer
    let glass: GlassRenderer
    let fx: FxRenderer
    let viz: ReelViz
    let enc: ReelEnc
    let base: MTLTexture
    let text: MTLTexture
    let emission: MTLTexture
    let lit: MTLTexture
    let backdrop: MTLTexture
    let glassed: MTLTexture
    let stack: MTLTexture
    let overlay: MTLTexture
    let accum: MTLTexture
    let bloom: ReelBloom
    let layers: [ReelLayer]
    let gpuName: String

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw LightRendererError.metalUnavailable
        }
        self.device = device
        self.queue = queue
        self.gpuName = device.name.replacingOccurrences(of: "Apple ", with: "")
        self.ui = try ReelUIRenderer(device: device)
        self.ts = TextSystem()
        self.light = try LightRenderer(device: device, width: UInt32(reelW), height: UInt32(reelH), outputFormat: .rgba16Float)
        self.glass = try GlassRenderer(device: device, pixelFormat: .rgba16Float)
        self.fx = try FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: false))
        self.viz = try ReelViz(device: device, gs: light.inspect().giSize)
        self.enc = try ReelEnc(device: device)
        self.base = reelMakeTexture(device: device, label: "ui base", width: reelW, height: reelH)
        self.text = reelMakeTexture(device: device, label: "ui text", width: reelW, height: reelH)
        self.emission = reelMakeTexture(device: device, label: "emission", width: reelW, height: reelH)
        self.lit = reelMakeTexture(device: device, label: "lit", width: reelW, height: reelH)
        self.backdrop = reelMakeTexture(device: device, label: "backdrop", width: reelW, height: reelH)
        self.glassed = reelMakeTexture(device: device, label: "glassed", width: reelW, height: reelH)
        self.stack = reelMakeTexture(device: device, label: "stack", width: reelW, height: reelH)
        self.overlay = reelMakeTexture(device: device, label: "overlay", width: reelW, height: reelH)
        self.accum = reelMakeTexture(device: device, label: "accum", width: reelW, height: reelH)
        self.bloom = try ReelBloom(device: device)
        self.layers = (0..<10).map { ReelLayer(device: device, label: "layer \($0)") }
    }

    func drawRune(_ insts: [ReelUIInst], target: MTLTexture, clear: MTLClearColor) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        ui.draw(commandBuffer: cmd, target: target, clear: clear, insts: insts, glyphAtlas: ts.glyphAtlas)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    func copy(_ cmd: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture) {
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: src,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: reelW, height: reelH, depth: 1),
            to: dst,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    func bindViz(_ re: MTLRenderCommandEncoder, level: Int, layer: MTLTexture? = nil) {
        let ins = light.inspect()
        re.setVertexBuffer(viz.gBuffer, offset: 0, index: 0)
        re.setVertexBuffer(viz.vpBuffer, offset: 0, index: 1)
        re.setFragmentBuffer(viz.gBuffer, offset: 0, index: 0)
        re.setFragmentBuffer(viz.vpBuffer, offset: 0, index: 1)
        re.setFragmentTexture(ins.field, index: 0)
        re.setFragmentTexture(ins.emission, index: 1)
        re.setFragmentTexture(ins.occluders, index: 2)
        re.setFragmentTexture(level < ins.own.count ? ins.own[level] : viz.dummy, index: 3)
        re.setFragmentTexture(level < ins.merged.count ? ins.merged[level] : viz.dummy, index: 4)
        re.setFragmentTexture(viz.meansOwn[level], index: 5)
        re.setFragmentTexture(viz.meansMrg[level], index: 6)
        re.setFragmentTexture(ins.fluence, index: 7)
        re.setFragmentTexture(layer ?? viz.dummy, index: 8)
        re.setFragmentSamplerState(viz.linSampler, index: 0)
        re.setFragmentSamplerState(viz.anisoSampler, index: 1)
    }

    func means(_ cmd: MTLCommandBuffer) {
        let ins = light.inspect()
        guard let ce = cmd.makeComputeCommandEncoder() else { return }
        ce.setComputePipelineState(viz.mean)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        for n in 0..<Int(lightCascades) {
            var mu = viz.meanUniforms[n]
            ce.setBytes(&mu, length: MemoryLayout<ReelMeanU>.stride, index: 0)
            let w = Int(max(ins.giSize.0 >> n, 1))
            let h = Int(max(ins.giSize.1 >> n, 1))
            let grid = MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: 1)
            let pairs: [(MTLTexture?, MTLTexture)] = [
                (n < ins.own.count ? ins.own[n] : nil, viz.meansOwn[n]),
                (n < ins.merged.count ? ins.merged[n] : nil, viz.meansMrg[n]),
            ]
            for (src, dst) in pairs {
                guard let src else { continue }
                ce.setTexture(src, index: 0)
                ce.setTexture(dst, index: 1)
                ce.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            }
        }
        ce.endEncoding()
    }

    func buildMips(_ cmd: MTLCommandBuffer, layerIdx: Int) {
        for m in 1..<reelMips {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = layers[layerIdx].mips[m]
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            guard let re = cmd.makeRenderCommandEncoder(descriptor: rp) else { continue }
            re.setRenderPipelineState(viz.mip)
            bindViz(re, level: 0, layer: layers[layerIdx].mips[m - 1])
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            re.endEncoding()
        }
    }

    func runBloom(_ src: MTLTexture) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        var karis = ReelBloomU(p: SIMD4<Float>(1.0, 1.0, 0.0, 0.0))
        var plain = ReelBloomU(p: SIMD4<Float>(0.0, 1.0, 0.0, 0.0))
        for k in 0..<reelBloomLevels {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = bloom.levels[k]
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            guard let re = cmd.makeRenderCommandEncoder(descriptor: rp) else { continue }
            re.setRenderPipelineState(bloom.down)
            if k == 0 {
                re.setFragmentBytes(&karis, length: MemoryLayout<ReelBloomU>.stride, index: 0)
                re.setFragmentTexture(src, index: 0)
            } else {
                re.setFragmentBytes(&plain, length: MemoryLayout<ReelBloomU>.stride, index: 0)
                re.setFragmentTexture(bloom.levels[k - 1], index: 0)
            }
            re.setFragmentSamplerState(bloom.sampler, index: 0)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            re.endEncoding()
        }
        for k in (1..<reelBloomLevels).reversed() {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = bloom.levels[k - 1]
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            guard let re = cmd.makeRenderCommandEncoder(descriptor: rp) else { continue }
            re.setRenderPipelineState(bloom.up)
            re.setFragmentBytes(&plain, length: MemoryLayout<ReelBloomU>.stride, index: 0)
            re.setFragmentTexture(bloom.levels[k], index: 0)
            re.setFragmentSamplerState(bloom.sampler, index: 0)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            re.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    func encode(frame: MTLTexture, wantRGBA: Bool, wantYUV: Bool) -> (y8: [UInt8]?, y10: [UInt8]?, rgba: [UInt8]?) {
        let bloomMix: Float = 0.045
        var eu = ReelEncU(
            size: SIMD4<Float>(Float(reelW), Float(reelH), 1.0, 1.0),
            misc: SIMD4<Float>(bloomMix, 1.0 / Float(reelBloomLevels), 0.0, 0.0)
        )
        guard let cmd = queue.makeCommandBuffer(),
              let ce = cmd.makeComputeCommandEncoder() else {
            return (nil, nil, nil)
        }
        ce.setBytes(&eu, length: MemoryLayout<ReelEncU>.stride, index: 0)
        ce.setTexture(frame, index: 0)
        ce.setTexture(overlay, index: 1)
        ce.setTexture(enc.noise, index: 2)
        ce.setTexture(bloom.levels[0], index: 3)
        ce.setSamplerState(bloom.sampler, index: 0)
        ce.setBuffer(enc.y8, offset: 0, index: 1)
        ce.setBuffer(enc.y10, offset: 0, index: 2)
        ce.setBuffer(enc.rgbaBuf, offset: 0, index: 3)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        if wantYUV {
            ce.setComputePipelineState(enc.yuv)
            let w8 = reelW / 8
            let h2 = reelH / 2
            ce.dispatchThreadgroups(MTLSize(width: (w8 + 7) / 8, height: (h2 + 7) / 8, depth: 1), threadsPerThreadgroup: tg)
        }
        if wantRGBA {
            ce.setComputePipelineState(enc.rgba)
            ce.dispatchThreadgroups(MTLSize(width: (reelW + 7) / 8, height: (reelH + 7) / 8, depth: 1), threadsPerThreadgroup: tg)
        }
        ce.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let n = reelW * reelH
        let out8: [UInt8]? = wantYUV ? [UInt8](UnsafeBufferPointer(start: enc.y8.contents().assumingMemoryBound(to: UInt8.self), count: n * 3 / 2)) : nil
        let out10: [UInt8]? = wantYUV ? [UInt8](UnsafeBufferPointer(start: enc.y10.contents().assumingMemoryBound(to: UInt8.self), count: n * 3)) : nil
        let outRGBA: [UInt8]? = wantRGBA ? [UInt8](UnsafeBufferPointer(start: enc.rgbaBuf.contents().assumingMemoryBound(to: UInt8.self), count: n * 4)) : nil
        return (out8, out10, outRGBA)
    }
}
#endif
