import Foundation
#if canImport(Metal)
import Metal
#endif

public enum LightRendererError: Error, Sendable {
    case metalUnavailable
    case shaderCompileFailed(String)
}

#if canImport(Metal)
/// The GI pass's intermediate buffers, for inspection and visualisation. All are `.rgba16Float`.
public struct LightInspect: @unchecked Sendable {
    public let field: MTLTexture
    public let emission: MTLTexture
    public let occluders: MTLTexture
    public let merged: [MTLTexture]
    public let own: [MTLTexture]
    public let fluence: MTLTexture
    public let giSize: (UInt32, UInt32)
    public let texel: Float
    public let fieldSize: (UInt32, UInt32)
}

public typealias Inspect = LightInspect

public final class LightRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public private(set) var width: UInt32
    public private(set) var height: UInt32
    public private(set) var fieldSize: (UInt32, UInt32)
    public private(set) var giSize: (UInt32, UInt32)
    public let outputFormat: MTLPixelFormat

    /// When enabled, also traces each GI cascade's own interval without merging for `inspect().own`.
    public var inspectCascades: Bool = false
    /// Compute passes recorded by the last `render` call.
    public private(set) var computePasses: UInt32 = 0

    public let gbufPipeline: MTLRenderPipelineState
    public let fieldPipeline: MTLComputePipelineState
    public let shadowPipeline: MTLComputePipelineState
    public let giScenePipeline: MTLComputePipelineState
    public let giCascadePipeline: MTLComputePipelineState
    public let giFluencePipeline: MTLComputePipelineState
    public let compositePipeline: MTLRenderPipelineState
    public let linearSampler: MTLSamplerState

    private let frameBuffer: MTLBuffer
    private var primBuffer: MTLBuffer
    private var primCapacity: Int
    private let lightBuffer: MTLBuffer
    private let cascadeUniformBuffers: [MTLBuffer]
    private let ownUniformBuffers: [MTLBuffer]

    private var gb0Tex: MTLTexture
    private var gb1Tex: MTLTexture
    private var fieldTex: MTLTexture
    private var visTex: MTLTexture
    private var airTex: MTLTexture

    private let blackTex: MTLTexture
    private var giEmitTex: MTLTexture?
    private var giOccTex: MTLTexture?
    private var giFluenceTex: MTLTexture?
    private var giMergedTexs: [MTLTexture] = []
    private var giOwnTexs: [MTLTexture] = []

    internal var resourceIdentities: (frame: ObjectIdentifier, light: ObjectIdentifier, prim: ObjectIdentifier, gb0: ObjectIdentifier, vis: ObjectIdentifier) {
        (
            ObjectIdentifier(frameBuffer),
            ObjectIdentifier(lightBuffer),
            ObjectIdentifier(primBuffer),
            ObjectIdentifier(gb0Tex),
            ObjectIdentifier(visTex)
        )
    }

    private weak var lastCommandBuffer: MTLCommandBuffer?

    public init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        width: UInt32,
        height: UInt32,
        outputFormat: MTLPixelFormat = .bgra8Unorm
    ) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw LightRendererError.metalUnavailable
        }
        self.device = device
        self.commandQueue = queue
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.outputFormat = outputFormat
        self.fieldSize = ((self.width + 1) / 2, (self.height + 1) / 2)
        let gw = max((((self.width + 7) / 8) + 15) / 16 * 16, 16)
        let gh = max((((self.height + 7) / 8) + 15) / 16 * 16, 16)
        self.giSize = (gw, gh)

        func makeLib(_ source: String, _ name: String) throws -> MTLLibrary {
            do {
                return try device.makeLibrary(source: source, options: nil)
            } catch {
                throw LightRendererError.shaderCompileFailed("\(name): \(error)")
            }
        }

        let gbufLib = try makeLib(RuneLightShaders.gbufferShader, "gbuffer")
        guard let gbufVs = gbufLib.makeFunction(name: "gbuffer_vertex"),
              let gbufFs = gbufLib.makeFunction(name: "gbuffer_fragment") else {
            throw LightRendererError.shaderCompileFailed("Missing gbuffer entry points")
        }
        let gbufDesc = MTLRenderPipelineDescriptor()
        gbufDesc.vertexFunction = gbufVs
        gbufDesc.fragmentFunction = gbufFs
        gbufDesc.colorAttachments[0].pixelFormat = .rgba16Float
        gbufDesc.colorAttachments[1].pixelFormat = .r32Uint
        self.gbufPipeline = try device.makeRenderPipelineState(descriptor: gbufDesc)

        func makeCompute(_ source: String, _ fn: String, _ name: String) throws -> MTLComputePipelineState {
            let lib = try makeLib(source, name)
            guard let kernel = lib.makeFunction(name: fn) else {
                throw LightRendererError.shaderCompileFailed("Missing \(fn) kernel")
            }
            return try device.makeComputePipelineState(function: kernel)
        }

        self.fieldPipeline = try makeCompute(RuneLightShaders.fieldShader, "field_kernel", "field")
        self.shadowPipeline = try makeCompute(RuneLightShaders.shadowShader, "shadow_kernel", "shadow")
        self.giScenePipeline = try makeCompute(RuneLightShaders.giSceneShader, "gi_scene_kernel", "gi_scene")
        self.giCascadePipeline = try makeCompute(RuneLightShaders.giCascadeShader, "gi_cascade_kernel", "gi_cascade")
        self.giFluencePipeline = try makeCompute(RuneLightShaders.giFluenceShader, "gi_fluence_kernel", "gi_fluence")

        let compLib = try makeLib(RuneLightShaders.compositeShader, "composite")
        guard let compVs = compLib.makeFunction(name: "composite_vertex"),
              let compFs = compLib.makeFunction(name: "composite_fragment") else {
            throw LightRendererError.shaderCompileFailed("Missing composite entry points")
        }
        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction = compVs
        compDesc.fragmentFunction = compFs
        compDesc.colorAttachments[0].pixelFormat = outputFormat
        self.compositePipeline = try device.makeRenderPipelineState(descriptor: compDesc)

        let smpDesc = MTLSamplerDescriptor()
        smpDesc.minFilter = .linear
        smpDesc.magFilter = .linear
        smpDesc.sAddressMode = .clampToEdge
        smpDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: smpDesc) else {
            throw LightRendererError.metalUnavailable
        }
        self.linearSampler = sampler

        let cap = 256
        guard let frameBuffer = device.makeBuffer(
                  length: MemoryLayout<LightFrameUniforms>.stride,
                  options: .storageModeShared
              ),
              let primBuffer = Self.makePrimBuffer(device: device, capacity: cap),
              let lightBuffer = device.makeBuffer(
                  length: maxLights * MemoryLayout<Light>.stride,
                  options: .storageModeShared
              ) else {
            throw LightRendererError.metalUnavailable
        }
        self.frameBuffer = frameBuffer
        self.primBuffer = primBuffer
        self.primCapacity = cap
        self.lightBuffer = lightBuffer

        func makeCascadeBuffers(merge: UInt32) throws -> [MTLBuffer] {
            var list: [MTLBuffer] = []
            list.reserveCapacity(Int(lightCascades))
            for n in 0..<lightCascades {
                var u = CascadeUniforms(level: n, count: lightCascades, merge: merge)
                guard let buf = device.makeBuffer(
                    bytes: &u,
                    length: MemoryLayout<CascadeUniforms>.stride,
                    options: .storageModeShared
                ) else {
                    throw LightRendererError.metalUnavailable
                }
                list.append(buf)
            }
            return list
        }
        self.cascadeUniformBuffers = try makeCascadeBuffers(merge: 1)
        self.ownUniformBuffers = try makeCascadeBuffers(merge: 0)

        let blackDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        blackDesc.usage = [.shaderRead]
        blackDesc.storageMode = .shared
        guard let black = device.makeTexture(descriptor: blackDesc) else {
            throw LightRendererError.metalUnavailable
        }
        var zeros = [UInt16](repeating: 0, count: 4)
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zeros, bytesPerRow: 8)
        self.blackTex = black

        let targets = try Self.makeTargets(
            device: device,
            width: self.width,
            height: self.height,
            fieldSize: self.fieldSize
        )
        self.gb0Tex = targets.gb0
        self.gb1Tex = targets.gb1
        self.fieldTex = targets.field
        self.visTex = targets.vis
        self.airTex = targets.air
    }

    private static func makePrimBuffer(device: MTLDevice, capacity: Int) -> MTLBuffer? {
        device.makeBuffer(
            length: max(capacity, 1) * MemoryLayout<Prim>.stride,
            options: .storageModeShared
        )
    }

    private static func makeTexture(
        device: MTLDevice,
        format: MTLPixelFormat,
        width: UInt32,
        height: UInt32,
        arrayLength: Int = 1,
        usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: Int(max(width, 1)),
            height: Int(max(height, 1)),
            mipmapped: false
        )
        if arrayLength > 1 {
            desc.textureType = .type2DArray
            desc.arrayLength = arrayLength
        }
        desc.usage = usage
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw LightRendererError.metalUnavailable
        }
        return tex
    }

    private static func makeTargets(
        device: MTLDevice,
        width: UInt32,
        height: UInt32,
        fieldSize: (UInt32, UInt32)
    ) throws -> (gb0: MTLTexture, gb1: MTLTexture, field: MTLTexture, vis: MTLTexture, air: MTLTexture) {
        let rt: MTLTextureUsage = [.renderTarget, .shaderRead]
        let st: MTLTextureUsage = [.shaderWrite, .shaderRead]
        let gb0 = try makeTexture(device: device, format: .rgba16Float, width: width, height: height, usage: rt)
        let gb1 = try makeTexture(device: device, format: .r32Uint, width: width, height: height, usage: rt)
        let field = try makeTexture(device: device, format: .rgba16Float, width: fieldSize.0, height: fieldSize.1, usage: st)
        let vis = try makeTexture(device: device, format: .rgba16Float, width: fieldSize.0, height: fieldSize.1, arrayLength: 2, usage: st)
        let air = try makeTexture(device: device, format: .rgba16Float, width: fieldSize.0, height: fieldSize.1, arrayLength: 2, usage: st)
        return (gb0, gb1, field, vis, air)
    }

    private func ensureGITargets() throws {
        if giFluenceTex != nil { return }
        let st: MTLTextureUsage = [.shaderWrite, .shaderRead]
        giEmitTex = try Self.makeTexture(device: device, format: .rgba16Float, width: giSize.0, height: giSize.1, usage: st)
        giOccTex = try Self.makeTexture(device: device, format: .rgba16Float, width: giSize.0, height: giSize.1, usage: st)
        giFluenceTex = try Self.makeTexture(device: device, format: .rgba16Float, width: giSize.0, height: giSize.1, usage: st)
        giMergedTexs = try (0..<Int(lightCascades)).map { _ in
            try Self.makeTexture(device: device, format: .rgba16Float, width: giSize.0 * 2, height: giSize.1 * 2, usage: st)
        }
    }

    private func ensureOwnTargets() throws {
        if !giOwnTexs.isEmpty { return }
        let st: MTLTextureUsage = [.shaderWrite, .shaderRead]
        giOwnTexs = try (0..<Int(lightCascades)).map { _ in
            try Self.makeTexture(device: device, format: .rgba16Float, width: giSize.0 * 2, height: giSize.1 * 2, usage: st)
        }
    }

    public func buildFrameUniforms(scene: LightScene) -> LightFrameUniforms {
        let s = scene.settings
        let nl = min(scene.lights.count, maxLights)
        let zmax = scene.prims
            .filter { ($0.flags & flagOccluder) != 0 }
            .reduce(Float(0.0)) { max($0, $1.z.y) }
        let shafts = scene.lights.prefix(nl).contains { $0.extra.x > 0.0 }
        let anyEmit = scene.prims.contains { ($0.flags & flagEmissive) != 0 } || scene.emission != nil
        let giActive: GIParams? = s.gi.flatMap { g in
            (anyEmit || (g.bounce > 0.0 && nl > 0)) ? g : nil
        }
        let floatTarget = outputFormat == .rgba16Float || outputFormat == .rgba32Float
        let isSrgbFormat = outputFormat == .bgra8Unorm_srgb || outputFormat == .rgba8Unorm_srgb
        let encode = !isSrgbFormat && !floatTarget
        let extra = giActive != nil && scene.emission != nil
        let flags: UInt32 =
            (giActive != nil ? 1 : 0) |
            (shafts ? 2 : 0) |
            (encode ? 4 : 0) |
            (s.contactAO > 0.0 ? 8 : 0) |
            (extra ? 16 : 0)
        let g = giActive ?? GIParams(strength: 0, air: 0, bounce: 0, absorption: 0, emission: 0)

        var u = LightFrameUniforms()
        u.sf = SIMD4<Float>(Float(width), Float(height), Float(fieldSize.0), Float(fieldSize.1))
        u.gs = SIMD4<Float>(Float(giSize.0), Float(giSize.1), 0.5, giScale)
        u.ambient = SIMD4<Float>(s.ambient.x, s.ambient.y, s.ambient.z, s.exposure)
        u.counts = SIMD4<UInt32>(UInt32(scene.prims.count), UInt32(nl), lightCascades, flags)
        u.misc = SIMD4<Float>(zmax, s.time, s.seed, s.shaftsOver)
        u.text = SIMD4<Float>(s.text.floor, s.text.ceiling, s.text.lit, s.text.specular)
        u.gi = SIMD4<Float>(g.strength, g.air, g.bounce, g.absorption)
        u.bg = SIMD4<Float>(s.backgroundGloss, s.backgroundRoughness, s.contactAO, s.rim)
        u.ext = SIMD4<Float>(s.albedoFloor, g.emission, 0.0, 0.0)
        return u
    }

    public func hasActiveLighting(_ scene: LightScene) -> Bool {
        let anyEmit = scene.prims.contains { ($0.flags & flagEmissive) != 0 } || scene.emission != nil
        return !(scene.lights.isEmpty && !(anyEmit && scene.settings.gi != nil))
    }

    /// Records the lighting passes into `commandBuffer`. Returns `false` if there are no lights and no GI emitters.
    @discardableResult
    public func render(
        scene: LightScene,
        commandBuffer: MTLCommandBuffer,
        baseTexture: MTLTexture,
        textTexture: MTLTexture,
        targetTexture: MTLTexture
    ) -> Bool {
        guard hasActiveLighting(scene) else {
            computePasses = 0
            return false
        }

        if scene.prims.count > primCapacity {
            var nextCap = max(primCapacity, 1)
            while nextCap < scene.prims.count { nextCap *= 2 }
            if let resized = Self.makePrimBuffer(device: device, capacity: nextCap) {
                primBuffer = resized
                primCapacity = nextCap
            }
        }

        if !scene.prims.isEmpty {
            _ = scene.prims.withUnsafeBytes { raw in
                memcpy(primBuffer.contents(), raw.baseAddress!, raw.count)
            }
        }
        let nl = min(scene.lights.count, maxLights)
        if nl > 0 {
            _ = scene.lights.prefix(nl).withUnsafeBytes { raw in
                memcpy(lightBuffer.contents(), raw.baseAddress!, raw.count)
            }
        }

        var frameU = buildFrameUniforms(scene: scene)
        let giEnabled = (frameU.counts.w & 1) != 0
        if giEnabled {
            do {
                try ensureGITargets()
                if inspectCascades {
                    try ensureOwnTargets()
                }
            } catch {
                return false
            }
        }
        memcpy(frameBuffer.contents(), &frameU, MemoryLayout<LightFrameUniforms>.stride)

        var passes: UInt32 = 0

        // 1. Surface GBuffer pass
        let gPassDesc = MTLRenderPassDescriptor()
        gPassDesc.colorAttachments[0].texture = gb0Tex
        gPassDesc.colorAttachments[0].loadAction = .clear
        gPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 1e4, green: 0, blue: 0, alpha: 0)
        gPassDesc.colorAttachments[0].storeAction = .store
        gPassDesc.colorAttachments[1].texture = gb1Tex
        gPassDesc.colorAttachments[1].loadAction = .clear
        gPassDesc.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        gPassDesc.colorAttachments[1].storeAction = .store
        if let gEnc = commandBuffer.makeRenderCommandEncoder(descriptor: gPassDesc) {
            gEnc.label = "light surface"
            if !scene.prims.isEmpty {
                gEnc.setRenderPipelineState(gbufPipeline)
                gEnc.setVertexBuffer(frameBuffer, offset: 0, index: 0)
                gEnc.setVertexBuffer(primBuffer, offset: 0, index: 1)
                gEnc.setFragmentBuffer(frameBuffer, offset: 0, index: 0)
                gEnc.setFragmentBuffer(primBuffer, offset: 0, index: 1)
                gEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.prims.count)
            }
            gEnc.endEncoding()
        }

        // 2 & 3. Distance field (16x16 workgroup tile culling) + soft shadows (8x8)
        if let fEnc = commandBuffer.makeComputeCommandEncoder() {
            fEnc.label = "light field"
            fEnc.setComputePipelineState(fieldPipeline)
            fEnc.setBuffer(frameBuffer, offset: 0, index: 0)
            fEnc.setBuffer(primBuffer, offset: 0, index: 1)
            fEnc.setTexture(fieldTex, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let ng = MTLSize(
                width: max((Int(fieldSize.0) + 15) / 16, 1),
                height: max((Int(fieldSize.1) + 15) / 16, 1),
                depth: 1
            )
            fEnc.dispatchThreadgroups(ng, threadsPerThreadgroup: tg)
            fEnc.endEncoding()
            passes += 1
        }
        if let sEnc = commandBuffer.makeComputeCommandEncoder() {
            sEnc.label = "light shadows"
            sEnc.setComputePipelineState(shadowPipeline)
            sEnc.setBuffer(frameBuffer, offset: 0, index: 0)
            sEnc.setBuffer(lightBuffer, offset: 0, index: 1)
            sEnc.setTexture(fieldTex, index: 0)
            sEnc.setTexture(gb0Tex, index: 1)
            sEnc.setTexture(visTex, index: 2)
            sEnc.setTexture(airTex, index: 3)
            sEnc.setSamplerState(linearSampler, index: 0)
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let ng = MTLSize(
                width: max((Int(fieldSize.0) + 7) / 8, 1),
                height: max((Int(fieldSize.1) + 7) / 8, 1),
                depth: 1
            )
            sEnc.dispatchThreadgroups(ng, threadsPerThreadgroup: tg)
            sEnc.endEncoding()
            passes += 1
        }

        // 4. Radiance cascades GI (scene media -> cascades top down -> fluence)
        if giEnabled,
           let emitTex = giEmitTex,
           let occTex = giOccTex,
           let fluTex = giFluenceTex,
           giMergedTexs.count == Int(lightCascades) {
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let giGroups = MTLSize(
                width: max((Int(giSize.0) + 7) / 8, 1),
                height: max((Int(giSize.1) + 7) / 8, 1),
                depth: 1
            )
            let casGroups = MTLSize(
                width: max((Int(giSize.0) * 2 + 7) / 8, 1),
                height: max((Int(giSize.1) * 2 + 7) / 8, 1),
                depth: 1
            )

            if let scEnc = commandBuffer.makeComputeCommandEncoder() {
                scEnc.label = "gi scene"
                scEnc.setComputePipelineState(giScenePipeline)
                scEnc.setBuffer(frameBuffer, offset: 0, index: 0)
                scEnc.setBuffer(primBuffer, offset: 0, index: 1)
                scEnc.setBuffer(lightBuffer, offset: 0, index: 2)
                scEnc.setTexture(visTex, index: 0)
                scEnc.setTexture(scene.emission ?? blackTex, index: 1)
                scEnc.setTexture(emitTex, index: 2)
                scEnc.setTexture(occTex, index: 3)
                scEnc.setSamplerState(linearSampler, index: 0)
                scEnc.dispatchThreadgroups(giGroups, threadsPerThreadgroup: tg)
                scEnc.endEncoding()
                passes += 1
            }

            for k in 0..<Int(lightCascades) {
                let n = Int(lightCascades) - 1 - k
                let upperTex = (n + 1 < Int(lightCascades)) ? giMergedTexs[n + 1] : blackTex
                if let cEnc = commandBuffer.makeComputeCommandEncoder() {
                    cEnc.label = "gi cascade \(n)"
                    cEnc.setComputePipelineState(giCascadePipeline)
                    cEnc.setBuffer(frameBuffer, offset: 0, index: 0)
                    cEnc.setBuffer(cascadeUniformBuffers[n], offset: 0, index: 1)
                    cEnc.setTexture(emitTex, index: 0)
                    cEnc.setTexture(occTex, index: 1)
                    cEnc.setTexture(fieldTex, index: 2)
                    cEnc.setTexture(upperTex, index: 3)
                    cEnc.setTexture(gb0Tex, index: 4)
                    cEnc.setTexture(giMergedTexs[n], index: 5)
                    cEnc.setSamplerState(linearSampler, index: 0)
                    cEnc.dispatchThreadgroups(casGroups, threadsPerThreadgroup: tg)
                    cEnc.endEncoding()
                    passes += 1
                }
            }

            if let flEnc = commandBuffer.makeComputeCommandEncoder() {
                flEnc.label = "gi fluence"
                flEnc.setComputePipelineState(giFluencePipeline)
                flEnc.setBuffer(frameBuffer, offset: 0, index: 0)
                flEnc.setTexture(giMergedTexs[0], index: 0)
                flEnc.setTexture(fluTex, index: 1)
                flEnc.dispatchThreadgroups(giGroups, threadsPerThreadgroup: tg)
                flEnc.endEncoding()
                passes += 1
            }

            if inspectCascades && giOwnTexs.count == Int(lightCascades) {
                if let ownEnc = commandBuffer.makeComputeCommandEncoder() {
                    ownEnc.label = "gi inspect"
                    ownEnc.setComputePipelineState(giCascadePipeline)
                    ownEnc.setBuffer(frameBuffer, offset: 0, index: 0)
                    ownEnc.setTexture(emitTex, index: 0)
                    ownEnc.setTexture(occTex, index: 1)
                    ownEnc.setTexture(fieldTex, index: 2)
                    ownEnc.setTexture(blackTex, index: 3)
                    ownEnc.setTexture(gb0Tex, index: 4)
                    ownEnc.setSamplerState(linearSampler, index: 0)
                    for k in 0..<Int(lightCascades) {
                        let n = Int(lightCascades) - 1 - k
                        ownEnc.setBuffer(ownUniformBuffers[n], offset: 0, index: 1)
                        ownEnc.setTexture(giOwnTexs[n], index: 5)
                        ownEnc.dispatchThreadgroups(casGroups, threadsPerThreadgroup: tg)
                    }
                    ownEnc.endEncoding()
                    passes += 1
                }
            }
        }

        // 5. Full-res composite pass
        let fluenceInput = (giEnabled ? giFluenceTex : nil) ?? blackTex
        let cPassDesc = MTLRenderPassDescriptor()
        cPassDesc.colorAttachments[0].texture = targetTexture
        cPassDesc.colorAttachments[0].loadAction = .clear
        cPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        cPassDesc.colorAttachments[0].storeAction = .store
        if let cEnc = commandBuffer.makeRenderCommandEncoder(descriptor: cPassDesc) {
            cEnc.label = "light composite"
            cEnc.setRenderPipelineState(compositePipeline)
            cEnc.setFragmentBuffer(frameBuffer, offset: 0, index: 0)
            cEnc.setFragmentBuffer(primBuffer, offset: 0, index: 1)
            cEnc.setFragmentBuffer(lightBuffer, offset: 0, index: 2)
            cEnc.setFragmentTexture(baseTexture, index: 0)
            cEnc.setFragmentTexture(textTexture, index: 1)
            cEnc.setFragmentTexture(gb0Tex, index: 2)
            cEnc.setFragmentTexture(gb1Tex, index: 3)
            cEnc.setFragmentTexture(visTex, index: 4)
            cEnc.setFragmentTexture(airTex, index: 5)
            cEnc.setFragmentTexture(fluenceInput, index: 6)
            cEnc.setFragmentTexture(fieldTex, index: 7)
            cEnc.setFragmentSamplerState(linearSampler, index: 0)
            cEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            cEnc.endEncoding()
        }

        computePasses = passes
        lastCommandBuffer = commandBuffer
        return true
    }

    public var visibilityTexture: MTLTexture {
        visTex
    }

    public func inspect() -> LightInspect {
        let blacks = [MTLTexture](repeating: blackTex, count: Int(lightCascades))
        return LightInspect(
            field: fieldTex,
            emission: giEmitTex ?? blackTex,
            occluders: giOccTex ?? blackTex,
            merged: giMergedTexs.isEmpty ? blacks : giMergedTexs,
            own: giOwnTexs.isEmpty ? blacks : giOwnTexs,
            fluence: giFluenceTex ?? blackTex,
            giSize: giSize,
            texel: 1.0 / giScale,
            fieldSize: fieldSize
        )
    }

    public func readTimings(commandBuffer: MTLCommandBuffer? = nil) -> LightTimings? {
        let cb = commandBuffer ?? lastCommandBuffer
        guard let cb else {
            return nil
        }
        if cb.status != .completed && cb.status != .error {
            cb.waitUntilCompleted()
        }
        guard cb.status == .completed else {
            return nil
        }
        // Per-pass Metal counter sampling is not attached here; report only the measured
        // command buffer GPU duration in `total`/`raster` and leave unmeasured passes at 0.
        let elapsedMs = max((cb.gpuEndTime - cb.gpuStartTime) * 1000.0, 0.0)
        var t = LightTimings()
        t.total = elapsedMs
        t.raster = elapsedMs
        return t
    }
}
#else
public final class LightRenderer: @unchecked Sendable {
    public init(width: UInt32, height: UInt32) throws {
        throw LightRendererError.metalUnavailable
    }
}
#endif
