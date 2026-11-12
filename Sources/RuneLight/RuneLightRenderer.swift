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

    public let gbufPipeline: MTLRenderPipelineState
    public let fieldPipeline: MTLComputePipelineState
    public let shadowPipeline: MTLComputePipelineState
    public let giScenePipeline: MTLComputePipelineState
    public let giCascadePipeline: MTLComputePipelineState
    public let giFluencePipeline: MTLComputePipelineState
    public let compositePipeline: MTLRenderPipelineState

    private let samplerLinear: MTLSamplerState
    private var gbufTex: MTLTexture
    private var idTex: MTLTexture
    private var fieldTex: MTLTexture
    private var visTex: MTLTexture
    private var airTex: MTLTexture
    private var giEmitTex: MTLTexture
    private var giOccTex: MTLTexture
    private var giFluenceTex: MTLTexture
    private var giMergedTexs: [MTLTexture]
    private var giOwnTexs: [MTLTexture]
    private var lastTimings: LightTimings?
    private weak var lastCommandBuffer: MTLCommandBuffer?

    public init(
        device: MTLDevice? = nil,
        width: UInt32,
        height: UInt32,
        outputFormat: MTLPixelFormat = .bgra8Unorm_srgb
    ) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            throw LightRendererError.metalUnavailable
        }
        self.device = dev
        self.commandQueue = queue
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.fieldSize = ((self.width + 1) / 2, (self.height + 1) / 2)
        let gw = ((self.width + 7) / 8 + 15) / 16 * 16
        let gh = ((self.height + 7) / 8 + 15) / 16 * 16
        self.giSize = (max(gw, 16), max(gh, 16))
        self.outputFormat = outputFormat

        func compile(_ name: String, _ src: String) throws -> MTLLibrary {
            do {
                return try dev.makeLibrary(source: src, options: nil)
            } catch {
                throw LightRendererError.shaderCompileFailed("\(name): \(error)")
            }
        }

        let gbufLib = try compile("gbuffer", RuneLightShaders.gbufferShader)
        guard let gv = gbufLib.makeFunction(name: "light_gbuf_vertex"),
              let gf = gbufLib.makeFunction(name: "light_gbuf_fragment") else {
            throw LightRendererError.shaderCompileFailed("Missing gbuffer entry points")
        }
        let gdesc = MTLRenderPipelineDescriptor()
        gdesc.label = "rune-light-gbuffer"
        gdesc.vertexFunction = gv
        gdesc.fragmentFunction = gf
        gdesc.colorAttachments[0].pixelFormat = .rgba16Float
        gdesc.colorAttachments[1].pixelFormat = .r32Uint
        self.gbufPipeline = try dev.makeRenderPipelineState(descriptor: gdesc)

        let fieldLib = try compile("field", RuneLightShaders.fieldShader)
        guard let fk = fieldLib.makeFunction(name: "light_field_kernel") else {
            throw LightRendererError.shaderCompileFailed("Missing field kernel")
        }
        self.fieldPipeline = try dev.makeComputePipelineState(function: fk)

        let shadowLib = try compile("shadow", RuneLightShaders.shadowShader)
        guard let sk = shadowLib.makeFunction(name: "light_shadow_kernel") else {
            throw LightRendererError.shaderCompileFailed("Missing shadow kernel")
        }
        self.shadowPipeline = try dev.makeComputePipelineState(function: sk)

        let giSceneLib = try compile("gi_scene", RuneLightShaders.giSceneShader)
        guard let gsk = giSceneLib.makeFunction(name: "light_gi_scene_kernel") else {
            throw LightRendererError.shaderCompileFailed("Missing gi_scene kernel")
        }
        self.giScenePipeline = try dev.makeComputePipelineState(function: gsk)

        let giCascadeLib = try compile("gi_cascade", RuneLightShaders.giCascadeShader)
        guard let gck = giCascadeLib.makeFunction(name: "light_gi_cascade_kernel") else {
            throw LightRendererError.shaderCompileFailed("Missing gi_cascade kernel")
        }
        self.giCascadePipeline = try dev.makeComputePipelineState(function: gck)

        let giFluenceLib = try compile("gi_fluence", RuneLightShaders.giFluenceShader)
        guard let gfk = giFluenceLib.makeFunction(name: "light_gi_fluence_kernel") else {
            throw LightRendererError.shaderCompileFailed("Missing gi_fluence kernel")
        }
        self.giFluencePipeline = try dev.makeComputePipelineState(function: gfk)

        let compLib = try compile("composite", RuneLightShaders.compositeShader)
        guard let cv = compLib.makeFunction(name: "light_composite_vertex"),
              let cf = compLib.makeFunction(name: "light_composite_fragment") else {
            throw LightRendererError.shaderCompileFailed("Missing composite entry points")
        }
        let cdesc = MTLRenderPipelineDescriptor()
        cdesc.label = "rune-light-composite"
        cdesc.vertexFunction = cv
        cdesc.fragmentFunction = cf
        cdesc.colorAttachments[0].pixelFormat = outputFormat
        self.compositePipeline = try dev.makeRenderPipelineState(descriptor: cdesc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let smp = dev.makeSamplerState(descriptor: sd) else {
            throw LightRendererError.metalUnavailable
        }
        self.samplerLinear = smp

        (self.gbufTex, self.idTex, self.fieldTex, self.visTex, self.airTex) = Self.makeTargets(
            device: dev,
            width: self.width,
            height: self.height,
            fieldSize: self.fieldSize
        )
        let giTargets = Self.makeGITargets(device: dev, giSize: self.giSize)
        self.giEmitTex = giTargets.emit
        self.giOccTex = giTargets.occ
        self.giFluenceTex = giTargets.fluence
        self.giMergedTexs = giTargets.merged
        self.giOwnTexs = giTargets.own
    }

    private static func makeGITargets(
        device: MTLDevice,
        giSize: (UInt32, UInt32)
    ) -> (emit: MTLTexture, occ: MTLTexture, fluence: MTLTexture, merged: [MTLTexture], own: [MTLTexture]) {
        func giTex(_ label: String) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: Int(giSize.0),
                height: Int(giSize.1),
                mipmapped: false
            )
            td.usage = [.shaderRead, .shaderWrite]
            td.storageMode = .private
            let tex = device.makeTexture(descriptor: td)!
            tex.label = label
            return tex
        }
        let emit = giTex("light gi emit")
        let occ = giTex("light gi occ")
        let fluence = giTex("light gi fluence")
        let merged = (0..<Int(lightCascades)).map { giTex("light gi merged \($0)") }
        let own = (0..<Int(lightCascades)).map { giTex("light gi own \($0)") }
        return (emit, occ, fluence, merged, own)
    }

    private static func makeTargets(
        device: MTLDevice,
        width: UInt32,
        height: UInt32,
        fieldSize: (UInt32, UInt32)
    ) -> (MTLTexture, MTLTexture, MTLTexture, MTLTexture, MTLTexture) {
        func tex2D(_ w: UInt32, _ h: UInt32, _ fmt: MTLPixelFormat, _ usage: MTLTextureUsage, layers: Int = 1) -> MTLTexture {
            let td = MTLTextureDescriptor()
            td.textureType = layers > 1 ? .type2DArray : .type2D
            td.width = Int(w)
            td.height = Int(h)
            td.arrayLength = layers
            td.pixelFormat = fmt
            td.usage = usage
            td.storageMode = .private
            return device.makeTexture(descriptor: td)!
        }
        let gbuf = tex2D(width, height, .rgba16Float, [.renderTarget, .shaderRead])
        let id = tex2D(width, height, .r32Uint, [.renderTarget, .shaderRead])
        let field = tex2D(fieldSize.0, fieldSize.1, .rgba16Float, [.shaderRead, .shaderWrite])
        let vis = tex2D(fieldSize.0, fieldSize.1, .rgba16Float, [.shaderRead, .shaderWrite], layers: 2)
        let air = tex2D(fieldSize.0, fieldSize.1, .rgba16Float, [.shaderRead, .shaderWrite], layers: 2)
        return (gbuf, id, field, vis, air)
    }

    public func buildFrameUniforms(scene: LightScene) -> LightFrameUniforms {
        let s = scene.settings
        var u = LightFrameUniforms()
        u.sf = SIMD4<Float>(Float(width), Float(height), Float(fieldSize.0), Float(fieldSize.1))
        u.gs = SIMD4<Float>(Float(giSize.0), Float(giSize.1), 0.5, giScale)
        u.ambient = SIMD4<Float>(s.ambient.x, s.ambient.y, s.ambient.z, s.exposure)
        u.counts = SIMD4<UInt32>(
            UInt32(scene.prims.count),
            UInt32(min(scene.lights.count, maxLights)),
            s.gi != nil ? 1 : 0,
            0
        )
        u.misc = SIMD4<Float>(s.contactAO, s.rim, s.shaftsOver, s.albedoFloor)
        u.text = SIMD4<Float>(s.text.floor, s.text.ceiling, s.text.lit, s.text.specular)
        let gi = s.gi ?? GIParams()
        u.gi = SIMD4<Float>(gi.strength, gi.air, gi.bounce, gi.absorption)
        u.bg = SIMD4<Float>(s.backgroundGloss, s.backgroundRoughness, gi.emission, s.time)
        let needsManualSrgb = outputFormat == .bgra8Unorm || outputFormat == .rgba8Unorm
        u.ext = SIMD4<Float>(s.seed, needsManualSrgb ? 1.0 : 0.0, 0.0, 0.0)
        return u
    }

    public func hasActiveLighting(_ scene: LightScene) -> Bool {
        if !scene.lights.isEmpty { return true }
        if scene.settings.gi != nil && scene.prims.contains(where: { ($0.flags & flagEmissive) != 0 }) {
            return true
        }
        return false
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
        guard hasActiveLighting(scene) else { return false }

        var frameU = buildFrameUniforms(scene: scene)
        let prims = scene.prims.isEmpty ? [Prim.rect(0, 0, 0, 0)] : scene.prims
        let lights = scene.lights.isEmpty ? [Light.point(0, 0, 100).intensity(0)] : Array(scene.lights.prefix(maxLights))

        guard let primBuf = device.makeBuffer(bytes: prims, length: prims.count * MemoryLayout<Prim>.stride, options: .storageModeShared),
              let lightBuf = device.makeBuffer(bytes: lights, length: lights.count * MemoryLayout<Light>.stride, options: .storageModeShared) else {
            return false
        }

        // 1. Surface GBuffer pass
        let gPassDesc = MTLRenderPassDescriptor()
        gPassDesc.colorAttachments[0].texture = gbufTex
        gPassDesc.colorAttachments[0].loadAction = .clear
        gPassDesc.colorAttachments[0].storeAction = .store
        gPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 1e4, green: 0, blue: 0, alpha: 0)
        gPassDesc.colorAttachments[1].texture = idTex
        gPassDesc.colorAttachments[1].loadAction = .clear
        gPassDesc.colorAttachments[1].storeAction = .store
        gPassDesc.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let gEnc = commandBuffer.makeRenderCommandEncoder(descriptor: gPassDesc) {
            gEnc.setRenderPipelineState(gbufPipeline)
            gEnc.setVertexBytes(&frameU, length: MemoryLayout<LightFrameUniforms>.stride, index: 0)
            gEnc.setVertexBuffer(primBuf, offset: 0, index: 1)
            gEnc.setFragmentBuffer(primBuf, offset: 0, index: 1)
            gEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.prims.count)
            gEnc.endEncoding()
        }

        // 2. Field compute pass
        if let cEnc = commandBuffer.makeComputeCommandEncoder() {
            cEnc.setComputePipelineState(fieldPipeline)
            cEnc.setBytes(&frameU, length: MemoryLayout<LightFrameUniforms>.stride, index: 0)
            cEnc.setBuffer(primBuf, offset: 0, index: 1)
            cEnc.setTexture(fieldTex, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let ng = MTLSize(width: (Int(fieldSize.0) + 15) / 16, height: (Int(fieldSize.1) + 15) / 16, depth: 1)
            cEnc.dispatchThreadgroups(ng, threadsPerThreadgroup: tg)

            // 3. Soft shadow + god rays compute pass
            cEnc.setComputePipelineState(shadowPipeline)
            cEnc.setBytes(&frameU, length: MemoryLayout<LightFrameUniforms>.stride, index: 0)
            cEnc.setBuffer(lightBuf, offset: 0, index: 1)
            cEnc.setTexture(fieldTex, index: 0)
            cEnc.setTexture(gbufTex, index: 1)
            cEnc.setSamplerState(samplerLinear, index: 0)
            cEnc.setTexture(visTex, index: 2)
            cEnc.setTexture(airTex, index: 3)
            let layers = scene.lights.count > 4 ? 2 : 1
            let sng = MTLSize(width: (Int(fieldSize.0) + 15) / 16, height: (Int(fieldSize.1) + 15) / 16, depth: layers)
            cEnc.dispatchThreadgroups(sng, threadsPerThreadgroup: tg)
            cEnc.endEncoding()
        }

        // 4. Composite render pass
        let cPassDesc = MTLRenderPassDescriptor()
        cPassDesc.colorAttachments[0].texture = targetTexture
        cPassDesc.colorAttachments[0].loadAction = .clear
        cPassDesc.colorAttachments[0].storeAction = .store
        if let cEnc = commandBuffer.makeRenderCommandEncoder(descriptor: cPassDesc) {
            cEnc.setRenderPipelineState(compositePipeline)
            cEnc.setFragmentBytes(&frameU, length: MemoryLayout<LightFrameUniforms>.stride, index: 0)
            cEnc.setFragmentBuffer(primBuf, offset: 0, index: 1)
            cEnc.setFragmentBuffer(lightBuf, offset: 0, index: 2)
            cEnc.setFragmentTexture(baseTexture, index: 0)
            cEnc.setFragmentTexture(textTexture, index: 1)
            cEnc.setFragmentTexture(gbufTex, index: 2)
            cEnc.setFragmentTexture(idTex, index: 3)
            cEnc.setFragmentTexture(visTex, index: 4)
            cEnc.setFragmentTexture(airTex, index: 5)
            cEnc.setFragmentTexture(fieldTex, index: 6)
            cEnc.setFragmentTexture(fieldTex, index: 7)
            cEnc.setFragmentSamplerState(samplerLinear, index: 0)
            cEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            cEnc.endEncoding()
        }

        lastCommandBuffer = commandBuffer
        let hasGI = scene.settings.gi != nil
        lastTimings = LightTimings(
            field: 0,
            shadows: 0,
            gi: 0,
            giScene: 0,
            cascades: [Double](repeating: 0, count: Int(lightCascades)),
            fluence: 0,
            raster: 0,
            total: hasGI ? 0 : 0
        )

        return true
    }

    /// The half-resolution visibility texture (2 array layers × 4 lights), for debugging and CPU reference checks.
    public var visibilityTexture: MTLTexture {
        visTex
    }

    /// The GI pass's intermediate buffers from the last recorded frame.
    public func inspect() -> LightInspect {
        LightInspect(
            field: fieldTex,
            emission: giEmitTex,
            occluders: giOccTex,
            merged: giMergedTexs,
            own: giOwnTexs,
            fluence: giFluenceTex,
            giSize: giSize,
            texel: 1.0 / giScale,
            fieldSize: fieldSize
        )
    }

    /// Blocking read of the last submitted frame's pass timings.
    /// If `commandBuffer` is provided (or the last rendered command buffer is still in flight),
    /// waits until completion and derives GPU elapsed milliseconds from Metal's GPU timestamps.
    public func readTimings(commandBuffer: MTLCommandBuffer? = nil) -> LightTimings? {
        let cb = commandBuffer ?? lastCommandBuffer
        if let cb {
            if cb.status != .completed && cb.status != .error {
                cb.waitUntilCompleted()
            }
            let gpuMs = max((cb.gpuEndTime - cb.gpuStartTime) * 1000.0, 0.0)
            var t = lastTimings ?? LightTimings()
            t.total = gpuMs
            t.raster = max(gpuMs - t.field - t.shadows - t.gi, 0.0)
            lastTimings = t
            return t
        }
        return lastTimings
    }
}
#endif
