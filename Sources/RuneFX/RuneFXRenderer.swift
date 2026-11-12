import Foundation
#if canImport(Metal)
import Metal
#endif

public struct FxOptions: Sendable, Equatable {
    public var dither: Bool
    public var srgbBlend: Bool

    public init(dither: Bool = false, srgbBlend: Bool = false) {
        self.dither = dither
        self.srgbBlend = srgbBlend
    }
}

public struct FxStats: Sendable, Equatable {
    public var drawn: UInt32 = 0
    public var culledIdle: UInt32 = 0
    public var culledOffscreen: UInt32 = 0
    public var pixels: UInt64 = 0
    public var needsBackdrop: Bool = false

    public init(
        drawn: UInt32 = 0,
        culledIdle: UInt32 = 0,
        culledOffscreen: UInt32 = 0,
        pixels: UInt64 = 0,
        needsBackdrop: Bool = false
    ) {
        self.drawn = drawn
        self.culledIdle = culledIdle
        self.culledOffscreen = culledOffscreen
        self.pixels = pixels
        self.needsBackdrop = needsBackdrop
    }
}

public struct FxPreparedLayer: Sendable, Equatable {
    public let layerIndex: Int
    public let kind: FxEffectKind
    public let place: Place
    public let blend: FxBlend
    public let boundsPx: SIMD4<Float>
    public let blurPx: Float
    public let needsBackdrop: Bool
    public let backdropSrgb: Bool
    public let sourceSlot: UInt32?
    public let instanceIndex: UInt32
}

public struct FxRenderPassGraph: Sendable, Equatable {
    public enum Pass: Sendable, Equatable {
        case backdropBlur(maxSigmaPx: Float)
        case underEffects(count: Int)
        case overEffects(count: Int)
    }

    public let passes: [Pass]
    public let prepared: [FxPreparedLayer]
    public let instances: [FxInstRaw]
    public let tableData: [SIMD4<Float>]
    public let stats: FxStats

    public static func build(
        viewport: SIMD2<UInt32>,
        scale: Float,
        layers: [FxLayer],
        slots: [FxSlot]? = nil,
        srgbBlend: Bool = false
    ) -> FxRenderPassGraph {
        let vpW = Float(viewport.x)
        let vpH = Float(viewport.y)
        var stats = FxStats()
        var prepared: [FxPreparedLayer] = []
        var instances: [FxInstRaw] = []
        var tableData: [SIMD4<Float>] = []
        var maxBlurPx: Float = 0.0

        for (idx, layer) in layers.enumerated() {
            let slot = (slots != nil && idx < slots!.count) ? slots![idx] : FxSlot()
            let effScale = slot.scale > 0.0 ? slot.scale : scale
            guard let (kind, packedInst, boundsPt) = layer.pack() else {
                stats.culledIdle += 1
                continue
            }
            var inst = packedInst

            let bx0 = max(boundsPt.x * effScale, 0.0)
            let by0 = max(boundsPt.y * effScale, 0.0)
            let bx1 = min((boundsPt.x + boundsPt.w) * effScale, vpW)
            let by1 = min((boundsPt.y + boundsPt.h) * effScale, vpH)

            if bx1 <= bx0 || by1 <= by0 {
                stats.culledOffscreen += 1
                continue
            }

            inst.shape.y = effScale
            inst.bounds = SIMD4<Float>(bx0, by0, bx1, by1)
            inst.clip = slot.clip
            inst.fade = slot.fade

            let blendFlags = (slot.blend.code & 7) << 1
            let rmBit: UInt32 = layer.reducedMotion ? 1 : 0
            inst.t.w = Float(rmBit | blendFlags)

            layer.fillTables(into: &inst, data: &tableData)

            var blurPx: Float = 0.0
            if case .distort(.lens(let l)) = layer.fx, l.frost > 0.0 {
                blurPx = l.frost * FxPackConstants.lensFrostSigma * effScale
            } else if case .fill(let f) = layer.fx, case .flutedGlass(let fg) = f.style, fg.frost > 0.0 {
                blurPx = fg.frost * FxPackConstants.lensFrostSigma * effScale
            }
            maxBlurPx = max(maxBlurPx, blurPx)

            let needsBd = layer.fx.needsBackdrop || slot.blend.needsBackdrop
            if needsBd { stats.needsBackdrop = true }

            let instIndex = UInt32(instances.count)
            instances.append(inst)

            let wPx = UInt64(max(ceilf(bx1 - bx0), 0.0))
            let hPx = UInt64(max(ceilf(by1 - by0), 0.0))
            stats.pixels += wPx * hPx
            stats.drawn += 1

            prepared.append(FxPreparedLayer(
                layerIndex: idx,
                kind: kind,
                place: layer.place,
                blend: slot.blend,
                boundsPx: inst.bounds,
                blurPx: blurPx,
                needsBackdrop: needsBd,
                backdropSrgb: slot.backdropSrgb ?? srgbBlend,
                sourceSlot: layer.source?.slot,
                instanceIndex: instIndex
            ))
        }

        var passes: [Pass] = []
        if maxBlurPx > 0.0 {
            passes.append(.backdropBlur(maxSigmaPx: maxBlurPx))
        }
        let underCount = prepared.filter { $0.place == .under }.count
        if underCount > 0 {
            passes.append(.underEffects(count: underCount))
        }
        let overCount = prepared.filter { $0.place == .over }.count
        if overCount > 0 {
            passes.append(.overEffects(count: overCount))
        }

        return FxRenderPassGraph(
            passes: passes,
            prepared: prepared,
            instances: instances,
            tableData: tableData,
            stats: stats
        )
    }
}

public enum FxRendererError: Error, Sendable {
    case metalUnavailable
    case shaderCompileFailed(String)
    case textureCreationFailed
}

#if canImport(Metal)
/// A mask (text, icon) and its hierarchical blur mip pyramid, for `GlowStyle.mask` and mask shimmer.
public final class MaskPyramid: @unchecked Sendable {
    public static let pixelFormat: MTLPixelFormat = .rgba16Float

    public let texture: MTLTexture
    /// All mips: bind this as the layer source texture.
    public let view: MTLTexture
    /// One texture view per mip level (level 0 is the render target for the mask itself).
    public let levels: [MTLTexture]
    public let mips: Int
    public let size: SIMD2<UInt32>

    public init(device: MTLDevice, width: UInt32, height: UInt32) throws {
        let w = max(width, 1)
        let h = max(height, 1)
        let maxDim = max(w, h)
        let bitCount = 32 - maxDim.leadingZeroBitCount
        let mips = min(max(bitCount, 1), 7)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: Int(w),
            height: Int(h),
            mipmapped: true
        )
        desc.mipmapLevelCount = mips
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw FxRendererError.textureCreationFailed
        }
        texture.label = "fx mask pyramid"

        var levels: [MTLTexture] = []
        levels.reserveCapacity(mips)
        for m in 0..<mips {
            guard let levelView = texture.makeTextureView(
                pixelFormat: Self.pixelFormat,
                textureType: .type2D,
                levels: m..<(m + 1),
                slices: 0..<1
            ) else {
                throw FxRendererError.textureCreationFailed
            }
            levelView.label = "fx mask pyramid mip \(m)"
            levels.append(levelView)
        }

        self.texture = texture
        self.view = texture
        self.levels = levels
        self.mips = mips
        self.size = SIMD2<UInt32>(w, h)
    }

    public func level(_ index: Int) -> MTLTexture? {
        guard index >= 0 && index < levels.count else { return nil }
        return levels[index]
    }
}

public final class FxRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    public var options: FxOptions

    private let samplerLinear: MTLSamplerState
    private var libraries: [FxEffectKind: MTLLibrary] = [:]
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var blurLibrary: MTLLibrary?
    private var blurDownPipeline: MTLRenderPipelineState?
    private var blurUpPipeline: MTLRenderPipelineState?
    private var mipLibrary: MTLLibrary?
    private var mipPipeline: MTLRenderPipelineState?
    private var fireSimPipeline: MTLComputePipelineState?

    private struct PipelineKey: Hashable {
        let kind: FxEffectKind
        let screenBlend: Bool
        let format: MTLPixelFormat
    }

    public init(device: MTLDevice? = nil, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb, options: FxOptions = FxOptions()) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            throw FxRendererError.metalUnavailable
        }
        self.device = dev
        self.pixelFormat = pixelFormat
        self.options = options

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let smp = dev.makeSamplerState(descriptor: sd) else {
            throw FxRendererError.metalUnavailable
        }
        self.samplerLinear = smp
    }

    public func compileLibrary(for kind: FxEffectKind) throws -> MTLLibrary {
        if let lib = libraries[kind] { return lib }
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: RuneFXShaders.source(for: kind), options: nil)
        } catch {
            throw FxRendererError.shaderCompileFailed("\(kind.shaderName): \(error)")
        }
        libraries[kind] = lib
        return lib
    }

    public func pipeline(for kind: FxEffectKind, blend: FxBlend = .normal, format: MTLPixelFormat? = nil) throws -> MTLRenderPipelineState {
        let fmt = format ?? pixelFormat
        let isScreen = (blend == .screen)
        let key = PipelineKey(kind: kind, screenBlend: isScreen, format: fmt)
        if let cached = pipelines[key] { return cached }

        let lib = try compileLibrary(for: kind)
        guard let vert = lib.makeFunction(name: "fx_vertex"),
              let frag = lib.makeFunction(name: RuneFXShaders.fragmentEntryPoint(for: kind)) else {
            throw FxRendererError.shaderCompileFailed("Missing entry point for \(kind.shaderName)")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "rune-fx-\(kind.shaderName)"
        desc.vertexFunction = vert
        desc.fragmentFunction = frag
        if let att = desc.colorAttachments[0] {
            att.pixelFormat = fmt
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = isScreen ? .oneMinusSourceColor : .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        let pso = try device.makeRenderPipelineState(descriptor: desc)
        pipelines[key] = pso
        return pso
    }

    public func compileUtilityPipelines() throws {
        if blurDownPipeline == nil || blurUpPipeline == nil {
            let lib = try device.makeLibrary(source: RuneFXShaders.blurShader, options: nil)
            blurLibrary = lib
            guard let v = lib.makeFunction(name: "fx_blur_vertex"),
                  let fd = lib.makeFunction(name: "fx_blur_down_fragment"),
                  let fu = lib.makeFunction(name: "fx_blur_up_fragment") else {
                throw FxRendererError.shaderCompileFailed("Missing blur entry points")
            }
            let dd = MTLRenderPipelineDescriptor()
            dd.vertexFunction = v
            dd.fragmentFunction = fd
            dd.colorAttachments[0].pixelFormat = .rgba16Float
            blurDownPipeline = try device.makeRenderPipelineState(descriptor: dd)

            let du = MTLRenderPipelineDescriptor()
            du.vertexFunction = v
            du.fragmentFunction = fu
            du.colorAttachments[0].pixelFormat = .rgba16Float
            blurUpPipeline = try device.makeRenderPipelineState(descriptor: du)
        }

        if mipPipeline == nil {
            let lib = try device.makeLibrary(source: RuneFXShaders.mipShader, options: nil)
            mipLibrary = lib
            guard let v = lib.makeFunction(name: "fx_mip_vertex"),
                  let f = lib.makeFunction(name: "fx_mip_fragment") else {
                throw FxRendererError.shaderCompileFailed("Missing mip entry points")
            }
            let dm = MTLRenderPipelineDescriptor()
            dm.vertexFunction = v
            dm.fragmentFunction = f
            dm.colorAttachments[0].pixelFormat = .rgba16Float
            mipPipeline = try device.makeRenderPipelineState(descriptor: dm)
        }

        if fireSimPipeline == nil {
            let lib = try device.makeLibrary(source: RuneFXShaders.fireSimShader, options: nil)
            guard let k = lib.makeFunction(name: "fx_firesim_step_kernel") else {
                throw FxRendererError.shaderCompileFailed("Missing firesim kernel")
            }
            fireSimPipeline = try device.makeComputePipelineState(function: k)
        }
    }

    public func warmAll() throws {
        for kind in FxEffectKind.allCases {
            _ = try pipeline(for: kind, blend: .normal)
            _ = try pipeline(for: kind, blend: .screen)
        }
        try compileUtilityPipelines()
    }

    public func prepare(
        viewport: SIMD2<UInt32>,
        scale: Float,
        layers: [FxLayer],
        slots: [FxSlot]? = nil
    ) -> FxRenderPassGraph {
        FxRenderPassGraph.build(
            viewport: viewport,
            scale: scale,
            layers: layers,
            slots: slots,
            srgbBlend: options.srgbBlend
        )
    }

    public func encode(
        graph: FxRenderPassGraph,
        viewport: SIMD2<UInt32>,
        encoder: MTLRenderCommandEncoder,
        backdrop: MTLTexture? = nil,
        blurred: MTLTexture? = nil,
        sources: [MTLTexture] = [],
        place: Place? = nil
    ) throws {
        let items = place == nil ? graph.prepared : graph.prepared.filter { $0.place == place }
        if items.isEmpty || graph.instances.isEmpty { return }

        var globals = FxGlobals(
            viewport: SIMD2<Float>(Float(viewport.x), Float(viewport.y)),
            dither: options.dither ? 1.0 : 0.0,
            srgb: options.srgbBlend ? 1.0 : 0.0
        )
        encoder.setVertexBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)

        let instLen = graph.instances.count * MemoryLayout<FxInstRaw>.stride
        guard let instBuf = device.makeBuffer(bytes: graph.instances, length: instLen, options: .storageModeShared) else {
            return
        }
        encoder.setVertexBuffer(instBuf, offset: 0, index: 1)
        encoder.setFragmentBuffer(instBuf, offset: 0, index: 1)

        if !graph.tableData.isEmpty {
            let dataLen = graph.tableData.count * MemoryLayout<SIMD4<Float>>.stride
            if let dataBuf = device.makeBuffer(bytes: graph.tableData, length: dataLen, options: .storageModeShared) {
                encoder.setFragmentBuffer(dataBuf, offset: 0, index: 2)
            }
        }
        encoder.setFragmentSamplerState(samplerLinear, index: 0)
        if let backdrop { encoder.setFragmentTexture(backdrop, index: 0) }
        if let blurred { encoder.setFragmentTexture(blurred, index: 2) }

        for item in items {
            let pso = try pipeline(for: item.kind, blend: item.blend)
            encoder.setRenderPipelineState(pso)
            var enc = FxBackdropEncoding(encoded: item.backdropSrgb ? 1.0 : 0.0, present: backdrop != nil ? 1.0 : 0.0)
            encoder.setFragmentBytes(&enc, length: MemoryLayout<FxBackdropEncoding>.stride, index: 4)
            if let slot = item.sourceSlot, Int(slot) < sources.count {
                encoder.setFragmentTexture(sources[Int(slot)], index: 1)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1, baseInstance: Int(item.instanceIndex))
        }
    }

    /// Fill mips `1..<pyramid.mips` of a `MaskPyramid` from level 0 using the Jimenez 13-tap downsample shader.
    public func buildMips(commandBuffer: MTLCommandBuffer, pyramid: MaskPyramid) throws {
        guard pyramid.mips > 1 else { return }
        if mipPipeline == nil {
            try compileUtilityPipelines()
        }
        guard let mipPSO = mipPipeline else {
            throw FxRendererError.shaderCompileFailed("Missing mip pipeline")
        }

        for lvl in 1..<pyramid.mips {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = pyramid.levels[lvl]
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.colorAttachments[0].storeAction = .store

            guard let pass = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            pass.label = "fx mip \(lvl)"
            pass.setRenderPipelineState(mipPSO)
            pass.setFragmentTexture(pyramid.levels[lvl - 1], index: 0)
            pass.setFragmentSamplerState(samplerLinear, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            pass.endEncoding()
        }
    }
}
#endif
