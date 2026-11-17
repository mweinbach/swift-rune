import Foundation
import Rune
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

#if canImport(Metal)
public struct FxFrame {
    public var viewport: SIMD2<UInt32>
    public var scale: Float
    public var layers: [FxLayer]
    public var backdrop: MTLTexture?
    public var sources: [MTLTexture?]

    public init(
        viewport: SIMD2<UInt32>,
        scale: Float = 1.0,
        layers: [FxLayer],
        backdrop: MTLTexture? = nil,
        sources: [MTLTexture?] = []
    ) {
        self.viewport = viewport
        self.scale = scale
        self.layers = layers
        self.backdrop = backdrop
        self.sources = sources
    }
}
#endif

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
    public let fireSimGrid: Int?

    public init(
        layerIndex: Int,
        kind: FxEffectKind,
        place: Place,
        blend: FxBlend,
        boundsPx: SIMD4<Float>,
        blurPx: Float,
        needsBackdrop: Bool,
        backdropSrgb: Bool,
        sourceSlot: UInt32?,
        instanceIndex: UInt32,
        fireSimGrid: Int? = nil
    ) {
        self.layerIndex = layerIndex
        self.kind = kind
        self.place = place
        self.blend = blend
        self.boundsPx = boundsPx
        self.blurPx = blurPx
        self.needsBackdrop = needsBackdrop
        self.backdropSrgb = backdropSrgb
        self.sourceSlot = sourceSlot
        self.instanceIndex = instanceIndex
        self.fireSimGrid = fireSimGrid
    }
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
    /// Indexes into a simulation are valid only on the planner and frame that supplied them.
    let simulationID: UUID?
    let simulationFrame: UInt64?

    public static func build(
        viewport: SIMD2<UInt32>,
        scale: Float,
        layers: [FxLayer],
        slots: [FxSlot]? = nil,
        srgbBlend: Bool = false,
        hasBackdrop: Bool = false,
        fireSim: FireSim? = nil
    ) -> FxRenderPassGraph {
        let vpW = Float(viewport.x)
        let vpH = Float(viewport.y)
        var stats = FxStats()
        var prepared: [FxPreparedLayer] = []
        var instances: [FxInstRaw] = []
        var tableData: [SIMD4<Float>] = []
        var maxBlurPx: Float = 0.0

        fireSim?.beginFrame()

        for (idx, layer) in layers.enumerated() {
            let slot = (slots != nil && idx < slots!.count) ? slots![idx] : FxSlot()
            let effScale = slot.scale > 0.0 ? slot.scale : scale
            guard let (kind, packedInst, boundsPt) = layer.pack() else {
                stats.culledIdle += 1
                continue
            }
            var inst = packedInst

            let bx0 = max(floorf(boundsPt.x * effScale), floorf(slot.clip.x), 0.0)
            let by0 = max(floorf(boundsPt.y * effScale), floorf(slot.clip.y), 0.0)
            let bx1 = min(ceilf((boundsPt.x + boundsPt.w) * effScale), ceilf(slot.clip.z), vpW)
            let by1 = min(ceilf((boundsPt.y + boundsPt.h) * effScale), ceilf(slot.clip.w), vpH)

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

            var fireSimGrid: Int? = nil
            if case .fire(let fp) = layer.fx,
               fp.style == .top || fp.style == .heat,
               let sim = fireSim {
                let (gridIdx, ext) = sim.plan(
                    layer: layer,
                    params: fp,
                    domain: boundsPt,
                    frozen: layer.reducedMotion
                )
                inst.t.z = 4.0
                inst.aux = SIMD4<Float>(boundsPt.x, boundsPt.y, ext.x, ext.y)
                inst.p3.y = boundsPt.w
                inst.p3.z = boundsPt.h
                fireSimGrid = gridIdx
            }

            var blurPx: Float = 0.0
            if case .distort(.lens(let l)) = layer.fx, l.frost > 0.0 {
                blurPx = max(min(max(l.frost, 0.0), 1.0) * FxPackConstants.lensFrostSigma * effScale, 0.0)
            } else if case .fill(let f) = layer.fx, case .flutedGlass(let fg) = f.style, fg.frost > 0.0 {
                blurPx = max(min(max(fg.frost, 0.0), 1.0) * FxPackConstants.lensFrostSigma * effScale, 0.0)
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

            let defaultBdSrgb = hasBackdrop ? false : srgbBlend
            prepared.append(FxPreparedLayer(
                layerIndex: idx,
                kind: kind,
                place: layer.place,
                blend: slot.blend,
                boundsPx: inst.bounds,
                blurPx: blurPx,
                needsBackdrop: needsBd,
                backdropSrgb: slot.backdropSrgb ?? defaultBdSrgb,
                sourceSlot: layer.source?.slot,
                instanceIndex: instIndex,
                fireSimGrid: fireSimGrid
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
            stats: stats,
            simulationID: fireSim?.identity,
            simulationFrame: fireSim?.frame
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

private final class BlurPyramid {
    let size: SIMD2<UInt32>
    let downTexture: MTLTexture
    let upTexture: MTLTexture
    let down: [MTLTexture]
    let up: [MTLTexture]
    var result: MTLTexture { up[0] }

    static let maxMips = 6

    init?(device: MTLDevice, viewport: SIMD2<UInt32>) {
        let w = max((viewport.x + 1) / 2, 1)
        let h = max((viewport.y + 1) / 2, 1)
        let bitCount = 32 - max(w, h).leadingZeroBitCount
        let mips = min(Self.maxMips, max(bitCount, 1))

        func makeChain(_ label: String) -> (MTLTexture, [MTLTexture])? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: Int(w),
                height: Int(h),
                mipmapped: true
            )
            desc.mipmapLevelCount = mips
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = label
            var views: [MTLTexture] = []
            views.reserveCapacity(mips)
            for m in 0..<mips {
                guard let v = tex.makeTextureView(
                    pixelFormat: .rgba16Float,
                    textureType: .type2D,
                    levels: m..<(m + 1),
                    slices: 0..<1
                ) else { return nil }
                v.label = "\(label) mip \(m)"
                views.append(v)
            }
            return (tex, views)
        }

        guard let (dTex, dViews) = makeChain("fx blur down"),
              let (uTex, uViews) = makeChain("fx blur up") else {
            return nil
        }
        self.size = viewport
        self.downTexture = dTex
        self.upTexture = uTex
        self.down = dViews
        self.up = uViews
    }
}

public final class FxRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public private(set) var pixelFormat: MTLPixelFormat
    public var options: FxOptions
    private var explicitSrgb: Bool?

    private let samplerLinear: MTLSamplerState
    private let dummyTexture: MTLTexture
    private var formats: [MTLPixelFormat] = []
    private var libraries: [FxEffectKind: MTLLibrary] = [:]
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var blurLibrary: MTLLibrary?
    private var blurDownPipeline: MTLRenderPipelineState?
    private var blurUpPipeline: MTLRenderPipelineState?
    private var mipLibrary: MTLLibrary?
    private var mipPipeline: MTLRenderPipelineState?
    private var fireSimPipeline: MTLComputePipelineState?
    private var fireSimPipelines: FireSimPipelines?
    private var fireSim: FireSim?

    private var instBuffer: MTLBuffer
    private var instCapacity: Int
    private var tableBuffer: MTLBuffer
    private var tableCapacity: Int
    private var blurUniformsBuffer: MTLBuffer
    private static let blurSlots = 64
    private static let blurUniformStride = 256

    private var blurPyramid: BlurPyramid?
    private var blurSlot: Int = 0
    private var lastViewport: SIMD2<UInt32> = .zero
    private var lastGraph: FxRenderPassGraph?
    private var preparedByLayer: [Int: FxPreparedLayer] = [:]
    private var lastFrameBackdrop: MTLTexture?
    private var lastFrameSources: [MTLTexture?] = []
    private var layerBackdrops: [Int: MTLTexture] = [:]

    private struct BindKey: Hashable {
        let backdrop: ObjectIdentifier
        let source: ObjectIdentifier
        let blurred: ObjectIdentifier
        let encFlags: UInt8
    }
    private var currentBindCache: [BindKey: UInt64] = [:]
    private var previousBindCache: [BindKey: UInt64] = [:]
    private var nextBindID: UInt64 = 1
    private var layerBindIDs: [Int: UInt64] = [:]

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
        self.formats = [pixelFormat]

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

        let dummyDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        dummyDesc.usage = [.shaderRead]
        dummyDesc.storageMode = .shared
        guard let dummy = dev.makeTexture(descriptor: dummyDesc) else {
            throw FxRendererError.textureCreationFailed
        }
        dummy.label = "fx dummy"
        var zeroPixel: [UInt8] = [0, 0, 0, 0]
        dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zeroPixel, bytesPerRow: 4)
        self.dummyTexture = dummy

        self.instCapacity = 64
        guard let ib = dev.makeBuffer(length: max(64 * MemoryLayout<FxInstRaw>.stride, 256), options: .storageModeShared) else {
            throw FxRendererError.metalUnavailable
        }
        ib.label = "fx insts"
        self.instBuffer = ib

        self.tableCapacity = 4096
        guard let tb = dev.makeBuffer(length: max(4096 * MemoryLayout<SIMD4<Float>>.stride, 256), options: .storageModeShared) else {
            throw FxRendererError.metalUnavailable
        }
        tb.label = "fx tables"
        self.tableBuffer = tb

        guard let ub = dev.makeBuffer(length: Self.blurSlots * Self.blurUniformStride, options: .storageModeShared) else {
            throw FxRendererError.metalUnavailable
        }
        ub.label = "fx blur params"
        self.blurUniformsBuffer = ub
    }

    public func addFormat(_ format: MTLPixelFormat) {
        if !formats.contains(format) {
            formats.append(format)
        }
    }

    public var builtPipelines: Int {
        pipelines.count
    }

    public func setSrgbBlend(_ on: Bool) {
        options.srgbBlend = on
        explicitSrgb = on
    }

    private func resolveFormatForSrgb(_ srgb: Bool, format: MTLPixelFormat) -> MTLPixelFormat {
        if srgb {
            switch format {
            case .rgba8Unorm_srgb: return .rgba8Unorm
            case .bgra8Unorm_srgb: return .bgra8Unorm
            default: return format
            }
        } else {
            switch format {
            case .rgba8Unorm: return .rgba8Unorm_srgb
            case .bgra8Unorm: return .bgra8Unorm_srgb
            default: return format
            }
        }
    }

    public func compileLibrary(for kind: FxEffectKind) throws -> MTLLibrary {
        if let lib = libraries[kind] { return lib }
        let lib: MTLLibrary
        do {
            lib = try ShaderLibraryCache.load(
                named: "fx_\(kind.shaderName)",
                source: RuneFXShaders.source(for: kind),
                requiredFunction: "fx_vertex",
                bundle: .module,
                on: device
            )
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
            let lib = try ShaderLibraryCache.load(
                named: "fx_blur",
                source: RuneFXShaders.blurShader,
                requiredFunction: "fx_blur_vertex",
                bundle: .module,
                on: device
            )
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
            let lib = try ShaderLibraryCache.load(
                named: "fx_mip",
                source: RuneFXShaders.mipShader,
                requiredFunction: "fx_mip_vertex",
                bundle: .module,
                on: device
            )
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

        if fireSimPipeline == nil || fireSimPipelines == nil {
            let lib = try ShaderLibraryCache.load(
                named: "fx_firesim",
                source: RuneFXShaders.fireSimShader,
                requiredFunction: "fx_firesim_step_kernel",
                bundle: .module,
                on: device
            )
            if fireSimPipeline == nil {
                guard let k = lib.makeFunction(name: "fx_firesim_step_kernel") else {
                    throw FxRendererError.shaderCompileFailed("Missing firesim kernel")
                }
                fireSimPipeline = try device.makeComputePipelineState(function: k)
            }
            if fireSimPipelines == nil {
                fireSimPipelines = try FireSimPipelines(device: device, library: lib)
            }
        }
    }

    /// Enable or disable the fluid fire simulation (styles `.top` and `.heat`).
    public func setFireSim(_ on: Bool) {
        if on && fireSim == nil {
            fireSim = FireSim(device: device)
        } else if !on {
            fireSim = nil
        }
    }

    /// Whether `simulate(commandBuffer:)` has pending steps to record this frame.
    public var simulatePending: Bool {
        fireSim?.pending ?? false
    }

    /// Record this frame's planned fire simulation steps as one compute pass before drawing fire layers.
    @discardableResult
    public func simulate(commandBuffer: MTLCommandBuffer) throws -> Bool {
        guard let sim = fireSim, sim.pending else { return false }
        if fireSimPipelines == nil {
            try compileUtilityPipelines()
        }
        guard let pipelines = fireSimPipelines else { return false }
        return sim.record(commandBuffer: commandBuffer, pipelines: pipelines)
    }

    public func warmAll() throws {
        for kind in FxEffectKind.allCases {
            _ = try pipeline(for: kind, blend: .normal)
            _ = try pipeline(for: kind, blend: .screen)
        }
        try compileUtilityPipelines()
    }

    public func buildEveryPipeline() throws {
        for fmt in formats {
            for kind in FxEffectKind.allCases {
                _ = try pipeline(for: kind, blend: .normal, format: fmt)
                _ = try pipeline(for: kind, blend: .screen, format: fmt)
            }
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

    @discardableResult
    public func prepare(frame: FxFrame, slots: [FxSlot] = []) -> FxRenderPassGraph {
        if let srgb = explicitSrgb {
            let resolved = resolveFormatForSrgb(srgb, format: pixelFormat)
            addFormat(resolved)
            pixelFormat = resolved
        }

        let graph = FxRenderPassGraph.build(
            viewport: frame.viewport,
            scale: frame.scale,
            layers: frame.layers,
            slots: slots.isEmpty ? nil : slots,
            srgbBlend: options.srgbBlend,
            hasBackdrop: frame.backdrop != nil,
            fireSim: fireSim
        )

        previousBindCache = currentBindCache
        currentBindCache.removeAll(keepingCapacity: true)
        layerBindIDs.removeAll(keepingCapacity: true)
        layerBackdrops.removeAll(keepingCapacity: true)
        preparedByLayer.removeAll(keepingCapacity: true)

        lastViewport = frame.viewport
        lastGraph = graph
        lastFrameBackdrop = frame.backdrop
        lastFrameSources = frame.sources
        blurSlot = 0

        let wantsBlur = graph.prepared.contains { $0.blurPx > 0.0 }
        if wantsBlur {
            try? compileUtilityPipelines()
            if blurPyramid?.size != frame.viewport {
                blurPyramid = BlurPyramid(device: device, viewport: frame.viewport)
            }
        }

        uploadGraphBuffers(graph)

        for item in graph.prepared {
            preparedByLayer[item.layerIndex] = item
            let readsBd = item.needsBackdrop && frame.backdrop != nil
            let bdTex: MTLTexture = readsBd ? (frame.backdrop ?? dummyTexture) : dummyTexture
            let srcTex: MTLTexture = item.fireSimGrid.flatMap { fireSim?.finalTexture(at: $0) }
                ?? item.sourceSlot.flatMap { Int($0) < frame.sources.count ? frame.sources[Int($0)] : nil }
                ?? dummyTexture
            let blurredTex: MTLTexture = (item.blurPx > 0.0 && frame.backdrop != nil)
                ? (blurPyramid?.result ?? dummyTexture)
                : dummyTexture
            let encFlags: UInt8 = (readsBd ? 2 : 0) | (item.backdropSrgb ? 1 : 0)
            layerBindIDs[item.layerIndex] = resolveBindID(
                backdrop: bdTex,
                source: srcTex,
                blurred: blurredTex,
                encFlags: encFlags
            )
        }

        return graph
    }

    /// Expose cached resource-group identity for a prepared layer (or `nil` when culled), for tests.
    public func layerResourceHandle(_ layer: Int) -> UInt64? {
        layerBindIDs[layer]
    }

    public func setLayerBackdrop(_ backdrop: MTLTexture, layer: Int) {
        guard let item = preparedByLayer[layer], item.needsBackdrop else { return }
        layerBackdrops[layer] = backdrop
        let srcTex: MTLTexture = item.fireSimGrid.flatMap { fireSim?.finalTexture(at: $0) }
            ?? item.sourceSlot.flatMap { Int($0) < lastFrameSources.count ? lastFrameSources[Int($0)] : nil }
            ?? dummyTexture
        let blurredTex: MTLTexture = item.blurPx > 0.0 ? (blurPyramid?.result ?? dummyTexture) : dummyTexture
        let encFlags: UInt8 = 2 | (item.backdropSrgb ? 1 : 0)
        layerBindIDs[layer] = resolveBindID(
            backdrop: backdrop,
            source: srcTex,
            blurred: blurredTex,
            encFlags: encFlags
        )
    }

    @discardableResult
    public func blurBackdrop(commandBuffer: MTLCommandBuffer, backdrop: MTLTexture, layer: Int) throws -> Bool {
        setLayerBackdrop(backdrop, layer: layer)
        guard let item = preparedByLayer[layer], let graph = lastGraph, item.blurPx > 0.0 else { return false }
        if blurDownPipeline == nil || blurUpPipeline == nil {
            try compileUtilityPipelines()
        }
        if blurPyramid?.size != lastViewport {
            blurPyramid = BlurPyramid(device: device, viewport: lastViewport)
        }
        guard let pyr = blurPyramid,
              let downPSO = blurDownPipeline,
              let upPSO = blurUpPipeline else {
            return false
        }
        let mips = pyr.down.count
        guard mips >= 2, blurSlot + mips <= Self.blurSlots else { return false }

        let level = min(max(log2f(max(item.blurPx / 2.0, 1.0)), 0.0), Float(mips - 1))
        let n = min(max(Int(ceilf(level)), 1), mips - 1)
        let frac = min(max(level - Float(n - 1), 0.0), 1.0)
        let bounds = item.boundsPx
        let instance = graph.instances[Int(item.instanceIndex)]
        let scale = instance.shape.y
        let sampleMargin: Float
        if item.kind == .fill {
            // The fluted-glass shader samples across each rib, including chromatic dispersion.
            sampleMargin = 1.35 * abs(instance.p0.z) * (1 + 0.3 * abs(instance.p1.x)) * scale
        } else {
            // Lens magnification moves samples about the shape center before applying the bevel.
            let presence = instance.p1.x
            let mag = 1 + (instance.p0.w - 1) * presence
            let cx = (instance.rect.x + instance.rect.z / 2) * scale
            let cy = (instance.rect.y + instance.rect.w / 2) * scale
            let extent = max(abs(bounds.x - cx), abs(bounds.z - cx), abs(bounds.y - cy), abs(bounds.w - cy))
            let bend = 1.12 * abs(instance.p0.y) * presence * (1 + abs(instance.p0.z)) * scale
            sampleMargin = mag == 0 ? .infinity : extent * abs(1 / mag - 1) + bend / abs(mag)
        }

        // Propagate the support of the two filters backwards from the pixels the layer samples.
        // A bilinear up tap can reach two source texels, and a bilinear down tap can reach three.
        func texelSize(_ mip: Int) -> Float {
            max(Float(lastViewport.x) / Float(pyr.down[mip].width),
                Float(lastViewport.y) / Float(pyr.down[mip].height))
        }
        var upMargins = [Float](repeating: sampleMargin + texelSize(0), count: n + 1)
        for mip in 1...n {
            upMargins[mip] = upMargins[mip - 1] + 2 * texelSize(mip)
        }
        var downMargins = upMargins
        for mip in (0..<n).reversed() {
            downMargins[mip] = downMargins[mip + 1] + 3 * texelSize(mip)
        }

        let base = blurSlot
        blurSlot += mips

        let uBasePtr = blurUniformsBuffer.contents()
        for k in 0..<mips {
            var w = SIMD4<Float>(k + 1 == n ? frac : 1.0, 0.0, 0.0, 0.0)
            memcpy(uBasePtr.advanced(by: (base + k) * Self.blurUniformStride), &w, MemoryLayout<SIMD4<Float>>.stride)
        }

        // Update xf.xy = (1.0, min(blurPx / 3.0, 1.0)) in instBuffer so shaders use the blurred pyramid.
        if let xfOffset = MemoryLayout<FxInstRaw>.offset(of: \FxInstRaw.xf) {
            var xf = SIMD4<Float>(1.0, min(item.blurPx / 3.0, 1.0), 0.0, 0.0)
            let instOffset = Int(item.instanceIndex) * MemoryLayout<FxInstRaw>.stride + xfOffset
            memcpy(instBuffer.contents().advanced(by: instOffset), &xf, MemoryLayout<SIMD4<Float>>.stride)
        }

        func scissor(_ dst: MTLTexture, margin: Float) -> MTLScissorRect {
            let sx = Float(dst.width) / Float(lastViewport.x)
            let sy = Float(dst.height) / Float(lastViewport.y)
            let x0 = Int(max(0, floorf((bounds.x - margin) * sx)))
            let y0 = Int(max(0, floorf((bounds.y - margin) * sy)))
            let x1 = Int(min(Float(dst.width), ceilf((bounds.z + margin) * sx)))
            let y1 = Int(min(Float(dst.height), ceilf((bounds.w + margin) * sy)))
            return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        func runPass(pso: MTLRenderPipelineState, src: MTLTexture, fine: MTLTexture,
                     dst: MTLTexture, slot: Int, margin: Float) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            // Neighboring taps can cross the scissor at coarser levels. Loading
            // unwritten float texels can propagate NaNs through the entire blur.
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            rpd.colorAttachments[0].storeAction = .store
            guard let pass = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
            pass.label = "fx blur"
            pass.setScissorRect(scissor(dst, margin: margin))
            pass.setRenderPipelineState(pso)
            pass.setFragmentTexture(src, index: 0)
            pass.setFragmentTexture(fine, index: 1)
            pass.setFragmentSamplerState(samplerLinear, index: 0)
            pass.setFragmentBuffer(blurUniformsBuffer, offset: slot * Self.blurUniformStride, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            pass.endEncoding()
        }

        for m in 0...n {
            let src = (m == 0) ? backdrop : pyr.down[m - 1]
            runPass(pso: downPSO, src: src, fine: dummyTexture, dst: pyr.down[m], slot: base + m, margin: downMargins[m])
        }
        for m in (0..<n).reversed() {
            let src = (m + 1 == n) ? pyr.down[m + 1] : pyr.up[m + 1]
            runPass(pso: upPSO, src: src, fine: pyr.down[m], dst: pyr.up[m], slot: base + m, margin: upMargins[m])
        }
        return true
    }

    public func drawLayer(encoder: MTLRenderCommandEncoder, layer: Int) throws {
        try drawLayer(encoder: encoder, format: pixelFormat, origin: .zero, layer: layer)
    }

    public func drawLayer(
        encoder: MTLRenderCommandEncoder,
        format: MTLPixelFormat,
        origin: SIMD2<Float>,
        layer: Int
    ) throws {
        guard let item = preparedByLayer[layer],
              let graph = lastGraph,
              !graph.instances.isEmpty else { return }

        let pso = try pipeline(for: item.kind, blend: item.blend, format: format)
        let shifted = origin != .zero
        if shifted {
            encoder.setViewport(MTLViewport(
                originX: Double(-origin.x),
                originY: Double(-origin.y),
                width: Double(lastViewport.x),
                height: Double(lastViewport.y),
                znear: 0.0,
                zfar: 1.0
            ))
        }

        var globals = FxGlobals(
            viewport: SIMD2<Float>(Float(lastViewport.x), Float(lastViewport.y)),
            dither: options.dither ? 1.0 : 0.0,
            srgb: options.srgbBlend ? 1.0 : 0.0
        )
        encoder.setRenderPipelineState(pso)
        encoder.setVertexBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)
        encoder.setVertexBuffer(instBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(instBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(tableBuffer, offset: 0, index: 2)
        encoder.setFragmentSamplerState(samplerLinear, index: 0)

        let overrideBd = layerBackdrops[layer]
        let hasBd = (overrideBd != nil || lastFrameBackdrop != nil) && item.needsBackdrop
        let bdTex = hasBd ? (overrideBd ?? lastFrameBackdrop ?? dummyTexture) : dummyTexture
        let srcTex: MTLTexture = item.fireSimGrid.flatMap { fireSim?.finalTexture(at: $0) }
            ?? item.sourceSlot.flatMap { Int($0) < lastFrameSources.count ? lastFrameSources[Int($0)] : nil }
            ?? dummyTexture
        let blurredTex: MTLTexture = (item.blurPx > 0.0 && (overrideBd != nil || lastFrameBackdrop != nil))
            ? (blurPyramid?.result ?? dummyTexture)
            : dummyTexture

        encoder.setFragmentTexture(bdTex, index: 0)
        encoder.setFragmentTexture(srcTex, index: 1)
        encoder.setFragmentTexture(blurredTex, index: 2)

        var enc = FxBackdropEncoding(encoded: item.backdropSrgb ? 1.0 : 0.0, present: hasBd ? 1.0 : 0.0)
        encoder.setFragmentBytes(&enc, length: MemoryLayout<FxBackdropEncoding>.stride, index: 4)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1, baseInstance: Int(item.instanceIndex))

        if shifted {
            encoder.setViewport(MTLViewport(
                originX: 0.0,
                originY: 0.0,
                width: Double(lastViewport.x),
                height: Double(lastViewport.y),
                znear: 0.0,
                zfar: 1.0
            ))
        }
    }

    public func drawAll(encoder: MTLRenderCommandEncoder, layers: [FxLayer], place: Place? = nil) throws {
        for (i, l) in layers.enumerated() {
            if place == nil || place == l.place {
                try drawLayer(encoder: encoder, layer: i)
            }
        }
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

        uploadGraphBuffers(graph)

        var globals = FxGlobals(
            viewport: SIMD2<Float>(Float(viewport.x), Float(viewport.y)),
            dither: options.dither ? 1.0 : 0.0,
            srgb: options.srgbBlend ? 1.0 : 0.0
        )
        encoder.setVertexBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)
        encoder.setVertexBuffer(instBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(instBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(tableBuffer, offset: 0, index: 2)
        encoder.setFragmentSamplerState(samplerLinear, index: 0)
        encoder.setFragmentTexture(backdrop ?? dummyTexture, index: 0)
        encoder.setFragmentTexture(blurred ?? dummyTexture, index: 2)

        for item in items {
            let pso = try pipeline(for: item.kind, blend: item.blend)
            encoder.setRenderPipelineState(pso)
            var enc = FxBackdropEncoding(encoded: item.backdropSrgb ? 1.0 : 0.0, present: backdrop != nil ? 1.0 : 0.0)
            encoder.setFragmentBytes(&enc, length: MemoryLayout<FxBackdropEncoding>.stride, index: 4)
            let srcTex: MTLTexture = item.fireSimGrid.flatMap { fireSim?.finalTexture(at: $0) }
                ?? item.sourceSlot.flatMap { Int($0) < sources.count ? sources[Int($0)] : nil }
                ?? dummyTexture
            encoder.setFragmentTexture(srcTex, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1, baseInstance: Int(item.instanceIndex))
        }
    }

    /// Expose buffer identities for steady-frame allocation tests.
    internal var bufferIdentities: (insts: ObjectIdentifier, tables: ObjectIdentifier) {
        (ObjectIdentifier(instBuffer), ObjectIdentifier(tableBuffer))
    }

    private func resolveBindID(backdrop: MTLTexture, source: MTLTexture, blurred: MTLTexture, encFlags: UInt8) -> UInt64 {
        let key = BindKey(
            backdrop: ObjectIdentifier(backdrop),
            source: ObjectIdentifier(source),
            blurred: ObjectIdentifier(blurred),
            encFlags: encFlags
        )
        if let id = currentBindCache[key] { return id }
        if let id = previousBindCache[key] {
            currentBindCache[key] = id
            return id
        }
        let id = nextBindID
        nextBindID &+= 1
        currentBindCache[key] = id
        return id
    }

    private func uploadGraphBuffers(_ graph: FxRenderPassGraph) {
        if !graph.instances.isEmpty {
            if graph.instances.count > instCapacity {
                var newCap = max(instCapacity, 64)
                while newCap < graph.instances.count { newCap *= 2 }
                if let nb = device.makeBuffer(length: max(newCap * MemoryLayout<FxInstRaw>.stride, 256), options: .storageModeShared) {
                    nb.label = "fx insts"
                    instBuffer = nb
                    instCapacity = newCap
                }
            }
            graph.instances.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(instBuffer.contents(), base, raw.count)
                }
            }
        }
        if !graph.tableData.isEmpty {
            if graph.tableData.count > tableCapacity {
                var newCap = max(tableCapacity, 4096)
                while newCap < graph.tableData.count { newCap *= 2 }
                if let nb = device.makeBuffer(length: max(newCap * MemoryLayout<SIMD4<Float>>.stride, 256), options: .storageModeShared) {
                    nb.label = "fx tables"
                    tableBuffer = nb
                    tableCapacity = newCap
                }
            }
            graph.tableData.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(tableBuffer.contents(), base, raw.count)
                }
            }
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
