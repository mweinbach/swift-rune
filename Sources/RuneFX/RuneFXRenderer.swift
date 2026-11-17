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

    public private(set) var passes: [Pass] = []
    public private(set) var prepared: [FxPreparedLayer] = []
    public private(set) var instances: [FxInstRaw] = []
    public private(set) var tableData: [SIMD4<Float>] = []
    public private(set) var stats = FxStats()
    fileprivate var wantedPipelines: UInt32 = 0
    /// Indexes into a simulation are valid only on the planner and frame that supplied them.
    private(set) var simulationID: UUID?
    private(set) var simulationFrame: UInt64?

    public static func build(
        viewport: SIMD2<UInt32>,
        scale: Float,
        layers: [FxLayer],
        slots: [FxSlot]? = nil,
        srgbBlend: Bool = false,
        hasBackdrop: Bool = false,
        fireSim: FireSim? = nil
    ) -> FxRenderPassGraph {
        var graph = Self()
        graph.rebuild(viewport: viewport, scale: scale, layers: layers, slots: slots,
                      srgbBlend: srgbBlend, hasBackdrop: hasBackdrop, fireSim: fireSim)
        return graph
    }

    /// A renderer keeps one working graph. An application retaining a previous graph still
    /// sees a value snapshot through Array's copy-on-write storage.
    mutating func rebuild(
        viewport: SIMD2<UInt32>, scale: Float, layers: [FxLayer], slots: [FxSlot]?,
        srgbBlend: Bool, hasBackdrop: Bool = false, fireSim: FireSim? = nil
    ) {
        let vpW = Float(viewport.x)
        let vpH = Float(viewport.y)
        prepared.removeAll(keepingCapacity: true)
        instances.removeAll(keepingCapacity: true)
        tableData.removeAll(keepingCapacity: true)
        passes.removeAll(keepingCapacity: true)
        stats = FxStats()
        wantedPipelines = 0
        var maxBlurPx: Float = 0
        var underCount = 0

        fireSim?.beginFrame()

        for (idx, layer) in layers.enumerated() {
            let slot = slots.flatMap { idx < $0.count ? $0[idx] : nil } ?? FxSlot()
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
            wantedPipelines |= kind.pipelineBit(screen: slot.blend == .screen)
            if layer.place == .under { underCount += 1 }

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

        if maxBlurPx > 0.0 {
            passes.append(.backdropBlur(maxSigmaPx: maxBlurPx))
        }
        if underCount > 0 {
            passes.append(.underEffects(count: underCount))
        }
        let overCount = prepared.count - underCount
        if overCount > 0 {
            passes.append(.overEffects(count: overCount))
        }

        simulationID = fireSim?.identity
        simulationFrame = fireSim?.frame
    }
}

private extension FxEffectKind {
    func pipelineBit(screen: Bool) -> UInt32 { 1 << (rawValue * 2 + (screen ? 1 : 0)) }
}

public enum FxRendererError: Error, Sendable {
    case metalUnavailable
    case shaderCompileFailed(String)
    case textureCreationFailed
    case bufferUnavailable
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
    private var readyFamilies: [MTLPixelFormat: UInt32] = [:]
    private var blurLibrary: MTLLibrary?
    private var blurDownPipeline: MTLRenderPipelineState?
    private var blurUpPipeline: MTLRenderPipelineState?
    private var mipLibrary: MTLLibrary?
    private var mipPipeline: MTLRenderPipelineState?
    private var fireSimPipelines: FireSimPipelines?
    private var fireSim: FireSim?

    private let frameBuffers: FxMetalBuffers
    private var graphBuffers: FxMetalBuffers?
    private var frameUpload: Result<Void, Error> = .success(())
    private static let blurSlots = 64

    private var blurPyramid: BlurPyramid?
    private var blurSlot: Int = 0
    private var lastViewport: SIMD2<UInt32> = .zero
    private var scratchGraph = FxRenderPassGraph()
    private var lastGraph = FxRenderPassGraph()
    private var preparedBindings: [LayerBinding?] = []
    private var lastFrameSources: [MTLTexture?] = []
    private var frameResources = ResourceCache()
    private var graphResources = ResourceCache()

    private struct LayerBinding {
        let index: Int
        var resources: ResourceGroup
    }

    private struct BindKey: Hashable {
        let backdrop: ObjectIdentifier
        let source: ObjectIdentifier
        let blurred: ObjectIdentifier
        let flags: UInt8
    }

    /// The textures are retained with their native bindings. A driver may reuse object
    /// addresses after deallocation, so caching identifiers alone is insufficient.
    private final class ResourceGroup {
        let id: UInt64
        let textures: [MTLTexture?]
        let encoding: FxBackdropEncoding

        init(id: UInt64, backdrop: MTLTexture, source: MTLTexture, blurred: MTLTexture, flags: UInt8) {
            self.id = id
            self.textures = [backdrop, source, blurred]
            self.encoding = FxBackdropEncoding(encoded: flags & 1 != 0 ? 1 : 0, present: flags & 2 != 0 ? 1 : 0)
        }

        func bind(_ encoder: MTLRenderCommandEncoder) {
            encoder.setFragmentTextures(textures, range: 0..<3)
            var parameters = encoding
            encoder.setFragmentBytes(&parameters, length: MemoryLayout<FxBackdropEncoding>.stride, index: 4)
        }
    }

    private struct ResourceCache {
        var current: [BindKey: ResourceGroup] = [:]
        var previous: [BindKey: ResourceGroup] = [:]
        var nextID: UInt64 = 1

        mutating func begin() {
            previous.removeAll(keepingCapacity: true)
            swap(&previous, &current)
        }

        mutating func group(backdrop: MTLTexture, source: MTLTexture, blurred: MTLTexture, flags: UInt8) -> ResourceGroup {
            let key = BindKey(backdrop: ObjectIdentifier(backdrop), source: ObjectIdentifier(source),
                              blurred: ObjectIdentifier(blurred), flags: flags)
            if let group = current[key] { return group }
            let group: ResourceGroup
            if let retained = previous.removeValue(forKey: key) {
                group = retained
            } else {
                group = ResourceGroup(id: nextID, backdrop: backdrop, source: source, blurred: blurred, flags: flags)
                nextID &+= 1
            }
            current[key] = group
            return group
        }
    }

    struct DrawStats: Equatable {
        var draws = 0
        var pipelineBinds = 0
        var resourceBinds = 0
    }
    private(set) var lastDrawStats = DrawStats()

    private struct PipelineKey: Hashable {
        let kind: FxEffectKind
        let screenBlend: Bool
        let format: MTLPixelFormat

        var bit: UInt32 { kind.pipelineBit(screen: screenBlend) }
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

        self.frameBuffers = try FxMetalBuffers(device: dev)
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

        let descriptor = try descriptor(for: key)
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = state
        readyFamilies[fmt, default: 0] |= key.bit
        return state
    }

    private func descriptor(for key: PipelineKey) throws -> MTLRenderPipelineDescriptor {
        let kind = key.kind
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
            att.pixelFormat = key.format
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = key.screenBlend ? .oneMinusSourceColor : .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return desc
    }

    /// Pipelines are cold only once per family, blend mode and target format. Resolve their
    /// shared libraries here, then let Metal compile the independent states concurrently.
    private func warm(format: MTLPixelFormat, wanted: UInt32) throws {
        let missing = wanted & ~(readyFamilies[format] ?? 0)
        guard missing != 0 else { return }
        var keys: [PipelineKey] = []
        for kind in FxEffectKind.allCases {
            for screen in [false, true] {
                let key = PipelineKey(kind: kind, screenBlend: screen, format: format)
                if missing & key.bit != 0 { keys.append(key) }
            }
        }
        let descriptors = try keys.map(descriptor(for:))
        let states = try FxMetalCompiler.compile(descriptors) { try self.device.makeRenderPipelineState(descriptor: $0) }
        for (key, state) in zip(keys, states) {
            pipelines[key] = state
            readyFamilies[format, default: 0] |= key.bit
        }
    }

    public func compileUtilityPipelines() throws {
        try compileBlur()
        try compileMips()
        try compileFireSim()
    }

    private func compileBlur() throws {
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

            let du = MTLRenderPipelineDescriptor()
            du.vertexFunction = v
            du.fragmentFunction = fu
            du.colorAttachments[0].pixelFormat = .rgba16Float
            let states = try FxMetalCompiler.compile([dd, du]) { try self.device.makeRenderPipelineState(descriptor: $0) }
            blurDownPipeline = states[0]
            blurUpPipeline = states[1]
        }
    }

    private func compileMips() throws {
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
    }

    private func compileFireSim() throws {
        if fireSimPipelines == nil {
            let lib = try ShaderLibraryCache.load(
                named: "fx_firesim",
                source: RuneFXShaders.fireSimShader,
                requiredFunction: "fx_firesim_step_kernel",
                bundle: .module,
                on: device
            )
            fireSimPipelines = try FireSimPipelines(device: device, library: lib)
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
        try simulate(commandBuffer: commandBuffer, pass: nil)
    }

    /// Supply a Metal compute pass descriptor to sample the fire simulation's start and end GPU timestamps.
    @discardableResult
    public func simulate(commandBuffer: MTLCommandBuffer, pass: MTLComputePassDescriptor?) throws -> Bool {
        guard let sim = fireSim, sim.pending else { return false }
        if fireSimPipelines == nil {
            try compileFireSim()
        }
        guard let pipelines = fireSimPipelines else { return false }
        return sim.record(commandBuffer: commandBuffer, pipelines: pipelines, pass: pass)
    }

    public func warmAll() throws {
        try warm(format: pixelFormat, wanted: (1 << (FxEffectKind.allCases.count * 2)) - 1)
        try compileUtilityPipelines()
    }

    public func buildEveryPipeline() throws {
        let all: UInt32 = (1 << (FxEffectKind.allCases.count * 2)) - 1
        for format in formats { try warm(format: format, wanted: all) }
        try compileUtilityPipelines()
    }

    public func prepare(
        viewport: SIMD2<UInt32>,
        scale: Float,
        layers: [FxLayer],
        slots: [FxSlot]? = nil
    ) -> FxRenderPassGraph {
        scratchGraph.rebuild(
            viewport: viewport,
            scale: scale,
            layers: layers,
            slots: slots,
            srgbBlend: options.srgbBlend
        )
        return scratchGraph
    }

    @discardableResult
    public func prepare(frame: FxFrame, slots: [FxSlot] = []) -> FxRenderPassGraph {
        if let srgb = explicitSrgb {
            let resolved = resolveFormatForSrgb(srgb, format: pixelFormat)
            addFormat(resolved)
            pixelFormat = resolved
        }

        lastGraph.rebuild(
            viewport: frame.viewport,
            scale: frame.scale,
            layers: frame.layers,
            slots: slots.isEmpty ? nil : slots,
            srgbBlend: options.srgbBlend,
            hasBackdrop: frame.backdrop != nil,
            fireSim: fireSim
        )

        frameResources.begin()
        preparedBindings.removeAll(keepingCapacity: true)
        lastViewport = frame.viewport
        let graph = lastGraph
        lastFrameSources = frame.sources
        blurSlot = 0

        if case .backdropBlur = graph.passes.first {
            try? compileBlur()
            if blurPyramid?.size != frame.viewport {
                blurPyramid = BlurPyramid(device: device, viewport: frame.viewport)
            }
        }

        frameUpload = Result { try frameBuffers.upload(graph) }

        for item in graph.prepared {
            let readsBd = item.needsBackdrop && frame.backdrop != nil
            let bdTex: MTLTexture = readsBd ? (frame.backdrop ?? dummyTexture) : dummyTexture
            let srcTex: MTLTexture = item.fireSimGrid.flatMap { fireSim?.finalTexture(at: $0) }
                ?? item.sourceSlot.flatMap { Int($0) < frame.sources.count ? frame.sources[Int($0)] : nil }
                ?? dummyTexture
            let blurredTex: MTLTexture = (item.blurPx > 0.0 && frame.backdrop != nil)
                ? (blurPyramid?.result ?? dummyTexture)
                : dummyTexture
            let encFlags: UInt8 = (readsBd ? 2 : 0) | (item.backdropSrgb ? 1 : 0)
            let group = frameResources.group(backdrop: bdTex, source: srcTex, blurred: blurredTex, flags: encFlags)
            while preparedBindings.count < item.layerIndex { preparedBindings.append(nil) }
            preparedBindings.append(LayerBinding(index: Int(item.instanceIndex), resources: group))
        }

        // Preserve the nonthrowing prepare API. drawLayer propagates a compilation error if
        // the device failed to produce a requested state.
        try? warm(format: pixelFormat, wanted: graph.wantedPipelines)
        return graph
    }

    /// Expose cached resource-group identity for a prepared layer (or `nil` when culled), for tests.
    public func layerResourceHandle(_ layer: Int) -> UInt64? {
        binding(at: layer)?.resources.id
    }

    public func setLayerBackdrop(_ backdrop: MTLTexture, layer: Int) {
        guard var binding = binding(at: layer) else { return }
        let item = lastGraph.prepared[binding.index]
        guard item.needsBackdrop else { return }
        let srcTex: MTLTexture = item.fireSimGrid.flatMap { fireSim?.finalTexture(at: $0) }
            ?? item.sourceSlot.flatMap { Int($0) < lastFrameSources.count ? lastFrameSources[Int($0)] : nil }
            ?? dummyTexture
        let blurredTex: MTLTexture = item.blurPx > 0.0 ? (blurPyramid?.result ?? dummyTexture) : dummyTexture
        let encFlags: UInt8 = 2 | (item.backdropSrgb ? 1 : 0)
        binding.resources = frameResources.group(backdrop: backdrop, source: srcTex, blurred: blurredTex, flags: encFlags)
        preparedBindings[layer] = binding
    }

    @discardableResult
    public func blurBackdrop(commandBuffer: MTLCommandBuffer, backdrop: MTLTexture, layer: Int) throws -> Bool {
        setLayerBackdrop(backdrop, layer: layer)
        guard let binding = binding(at: layer) else { return false }
        let item = lastGraph.prepared[binding.index]
        guard item.blurPx > 0 else { return false }
        if blurDownPipeline == nil || blurUpPipeline == nil {
            try compileBlur()
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
        let instance = lastGraph.instances[Int(item.instanceIndex)]
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

        blurSlot += mips

        // Mark the instance as sampling the blurred pyramid and set its strength.
        if let xfOffset = MemoryLayout<FxInstRaw>.offset(of: \FxInstRaw.xf) {
            var xf = SIMD4<Float>(1.0, min(item.blurPx / 3.0, 1.0), 0.0, 0.0)
            let instOffset = Int(item.instanceIndex) * MemoryLayout<FxInstRaw>.stride + xfOffset
            try frameUpload.get()
            try frameBuffers.instances.update(&xf, offset: instOffset)
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
                     dst: MTLTexture, mip: Int, margin: Float) {
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
            var weight = SIMD4<Float>(mip + 1 == n ? frac : 1, 0, 0, 0)
            pass.setFragmentBytes(&weight, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            pass.endEncoding()
        }

        for m in 0...n {
            let src = (m == 0) ? backdrop : pyr.down[m - 1]
            runPass(pso: downPSO, src: src, fine: dummyTexture, dst: pyr.down[m], mip: m, margin: downMargins[m])
        }
        for m in (0..<n).reversed() {
            let src = (m + 1 == n) ? pyr.down[m + 1] : pyr.up[m + 1]
            runPass(pso: upPSO, src: src, fine: pyr.down[m], dst: pyr.up[m], mip: m, margin: upMargins[m])
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
        guard let binding = binding(at: layer) else { return }
        let item = lastGraph.prepared[binding.index]
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

        try frameUpload.get()
        bindCommon(encoder, viewport: lastViewport, buffers: frameBuffers)
        encoder.setRenderPipelineState(pso)
        binding.resources.bind(encoder)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: 1, baseInstance: binding.index)
        lastDrawStats = DrawStats(draws: 1, pipelineBinds: 1, resourceBinds: 1)

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
        try frameUpload.get()
        try drawRuns(encoder: encoder, graph: lastGraph, viewport: lastViewport, buffers: frameBuffers) { item in
            guard layers.indices.contains(item.layerIndex),
                  place == nil || layers[item.layerIndex].place == place else { return nil }
            return self.preparedBindings[item.layerIndex]?.resources
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
        graphResources.begin()
        if graph.prepared.isEmpty {
            lastDrawStats = DrawStats()
            return
        }
        let buffers = try graphBuffers ?? FxMetalBuffers(device: device)
        graphBuffers = buffers
        try buffers.upload(graph)
        try warm(format: pixelFormat, wanted: graph.wantedPipelines)
        try drawRuns(encoder: encoder, graph: graph, viewport: viewport, buffers: buffers) { item in
            guard place == nil || item.place == place else { return nil }
            let source = item.fireSimGrid.flatMap { self.fireSim?.finalTexture(at: $0) }
                ?? item.sourceSlot.flatMap { Int($0) < sources.count ? sources[Int($0)] : nil }
                ?? self.dummyTexture
            let flags: UInt8 = (backdrop == nil ? 0 : 2) | (item.backdropSrgb ? 1 : 0)
            return self.graphResources.group(backdrop: backdrop ?? self.dummyTexture, source: source,
                                             blurred: blurred ?? self.dummyTexture, flags: flags)
        }
    }

    private func binding(at layer: Int) -> LayerBinding? {
        preparedBindings.indices.contains(layer) ? preparedBindings[layer] : nil
    }

    private func bindCommon(_ encoder: MTLRenderCommandEncoder, viewport: SIMD2<UInt32>, buffers: FxMetalBuffers) {
        var globals = FxGlobals(
            viewport: SIMD2<Float>(Float(viewport.x), Float(viewport.y)),
            dither: options.dither ? 1.0 : 0.0,
            srgb: options.srgbBlend ? 1.0 : 0.0
        )
        encoder.setVertexBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<FxGlobals>.stride, index: 0)
        buffers.instances.bind(encoder, at: 1, vertex: true)
        buffers.tables.bind(encoder, at: 2, vertex: false)
        encoder.setFragmentSamplerState(samplerLinear, index: 0)
    }

    /// Common, adjacent instances can use one triangle-strip draw. Keep all state local
    /// to this invocation: callers may interleave other renderers on a shared encoder.
    private func drawRuns(
        encoder: MTLRenderCommandEncoder, graph: FxRenderPassGraph, viewport: SIMD2<UInt32>,
        buffers: FxMetalBuffers, resources: (FxPreparedLayer) -> ResourceGroup?
    ) throws {
        var stats = DrawStats()
        defer { lastDrawStats = stats }
        var boundPipeline: PipelineKey?
        var boundResources: ResourceGroup?
        var start = 0
        var end = 0
        func flush() {
            if start < end {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: end - start, baseInstance: start)
                stats.draws += 1
            }
        }

        for item in graph.prepared {
            guard let group = resources(item) else { continue }
            let key = PipelineKey(kind: item.kind, screenBlend: item.blend == .screen, format: pixelFormat)
            let index = Int(item.instanceIndex)
            if end != index || key != boundPipeline || group !== boundResources {
                flush()
                if boundPipeline == nil { bindCommon(encoder, viewport: viewport, buffers: buffers) }
                if key != boundPipeline {
                    encoder.setRenderPipelineState(try pipeline(for: item.kind, blend: item.blend))
                    boundPipeline = key
                    stats.pipelineBinds += 1
                }
                if group !== boundResources {
                    group.bind(encoder)
                    boundResources = group
                    stats.resourceBinds += 1
                }
                start = index
            }
            end = index + 1
        }
        flush()
    }

    /// Expose buffer identities for steady-frame allocation tests.
    internal var bufferIdentities: (insts: ObjectIdentifier, tables: ObjectIdentifier) {
        (ObjectIdentifier(frameBuffers.instances.buffer), ObjectIdentifier(frameBuffers.tables.buffer))
    }

    /// Fill mips `1..<pyramid.mips` of a `MaskPyramid` from level 0 using the Jimenez 13-tap downsample shader.
    public func buildMips(commandBuffer: MTLCommandBuffer, pyramid: MaskPyramid) throws {
        guard pyramid.mips > 1 else { return }
        if mipPipeline == nil {
            try compileMips()
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
