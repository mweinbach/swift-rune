import Foundation
#if canImport(Metal)
import Metal
#endif

public let maxGlass = 8
public let maxGlassLights = 32
public let glassPyramidLevels: UInt32 = 7

/// One glass slab, in device pixels. 96 bytes (`6 × SIMD4<Float>`).
public struct Glass: Sendable, Equatable {
    public var a: SIMD4<Float>
    public var b: SIMD4<Float>
    public var r: SIMD4<Float>
    public var p0: SIMD4<Float>
    public var p1: SIMD4<Float>
    public var tint: SIMD4<Float>

    public init(
        a: SIMD4<Float>,
        b: SIMD4<Float> = .zero,
        r: SIMD4<Float> = .zero,
        p0: SIMD4<Float> = SIMD4<Float>(40.0, 30.0, 12.0, 0.0),
        p1: SIMD4<Float> = SIMD4<Float>(1.5, 0.03, 0.0, 1.0),
        tint: SIMD4<Float> = SIMD4<Float>(0.0016, 0.00045, 0.0011, 0.35)
    ) {
        self.a = a
        self.b = b
        self.r = r
        self.p0 = p0
        self.p1 = p1
        self.tint = tint
    }

    public static func rounded(_ x: Float, _ y: Float, _ w: Float, _ h: Float, radius: Float) -> Glass {
        Glass(a: SIMD4<Float>(x, y, w, h), r: SIMD4<Float>(radius, 0.0, 0.0, 0.0))
    }

    public func thickness(_ t: Float) -> Glass {
        var copy = self; copy.p0.x = t; return copy
    }

    public func bevel(_ b: Float) -> Glass {
        var copy = self; copy.p0.y = b; return copy
    }

    public func gap(_ g: Float) -> Glass {
        var copy = self; copy.p0.z = g; return copy
    }

    public func dome(_ d: Float) -> Glass {
        var copy = self; copy.p0.w = d; return copy
    }

    public func ior(_ n: Float) -> Glass {
        var copy = self; copy.p1.x = n; return copy
    }

    public func dispersion(_ d: Float) -> Glass {
        var copy = self; copy.p1.y = d; return copy
    }

    public func frost(_ f: Float) -> Glass {
        var copy = self; copy.p1.z = f; return copy
    }

    public func presence(_ p: Float) -> Glass {
        var copy = self; copy.p1.w = p; return copy
    }

    public func tint(_ absorb: SIMD3<Float>) -> Glass {
        var copy = self
        copy.tint.x = absorb.x
        copy.tint.y = absorb.y
        copy.tint.z = absorb.z
        return copy
    }

    public func rimGlow(_ g: Float) -> Glass {
        var copy = self; copy.tint.w = g; return copy
    }

    public func union(rect: SIMD4<Float>, radius: Float, k: Float, morph: Float) -> Glass {
        var copy = self
        copy.b = rect
        copy.r.y = radius
        copy.r.z = k
        copy.r.w = morph
        return copy
    }
}

/// 32-byte glass highlight sphere light.
public struct GlassLight: Sendable, Equatable {
    public var pos: SIMD4<Float>
    public var color: SIMD4<Float>

    public init(pos: SIMD4<Float>, color: SIMD4<Float>) {
        self.pos = pos
        self.color = color
    }

    public static func fromEmitter(_ p: Prim, z: Float, gain: Float) -> GlassLight? {
        guard (p.flags & flagEmissive) != 0 else { return nil }
        let r = 0.5 * sqrtf(max(p.rect.z * p.rect.w, 0.0))
        return GlassLight(
            pos: SIMD4<Float>(p.rect.x + p.rect.z * 0.5, p.rect.y + p.rect.w * 0.5, z, r),
            color: SIMD4<Float>(p.emit.x * gain, p.emit.y * gain, p.emit.z * gain, 0.0)
        )
    }
}

public struct GlassSettings: Sendable, Equatable {
    public var env: Float
    public var shadow: Float
    public var shadowOffset: SIMD2<Float>
    public var shadowBlur: Float
    public var caustic: Float

    public init(
        env: Float = 1.0,
        shadow: Float = 0.35,
        shadowOffset: SIMD2<Float> = SIMD2<Float>(8.0, 22.0),
        shadowBlur: Float = 30.0,
        caustic: Float = 0.6
    ) {
        self.env = env
        self.shadow = shadow
        self.shadowOffset = shadowOffset
        self.shadowBlur = shadowBlur
        self.caustic = caustic
    }
}

/// 48-byte Glass uniform (`3 × SIMD4<Float>`).
public struct GlassUniforms: Sendable, Equatable {
    public var size: SIMD4<Float> = .zero
    public var misc: SIMD4<Float> = .zero
    public var shadow: SIMD4<Float> = .zero

    public init() {}
}

#if canImport(Metal)
public final class GlassRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    public let mainPipeline: MTLRenderPipelineState
    public let pyramidPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    public private(set) var width: UInt32 = 0
    public private(set) var height: UInt32 = 0
    public private(set) var mips: UInt32 = 1

    private let uniformBuffer: MTLBuffer
    private let glassBuffer: MTLBuffer
    private let lightsBuffer: MTLBuffer
    private let blackTexture: MTLTexture
    private var pyramidTexture: MTLTexture?
    private var pyramidLevelViews: [MTLTexture] = []

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .rgba16Float) throws {
        guard let device else { throw LightRendererError.metalUnavailable }
        self.device = device
        self.pixelFormat = pixelFormat

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: RuneLightShaders.glassShader, options: nil)
        } catch {
            throw LightRendererError.shaderCompileFailed("glass: \(error)")
        }
        guard let vs = library.makeFunction(name: "glass_vertex"),
              let fs = library.makeFunction(name: "glass_fragment"),
              let pyrFs = library.makeFunction(name: "glass_pyramid_fragment") else {
            throw LightRendererError.shaderCompileFailed("Missing glass entry points")
        }

        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.vertexFunction = vs
        mainDesc.fragmentFunction = fs
        mainDesc.colorAttachments[0].pixelFormat = pixelFormat
        self.mainPipeline = try device.makeRenderPipelineState(descriptor: mainDesc)

        let pyrDesc = MTLRenderPipelineDescriptor()
        pyrDesc.vertexFunction = vs
        pyrDesc.fragmentFunction = pyrFs
        pyrDesc.colorAttachments[0].pixelFormat = .rgba16Float
        self.pyramidPipeline = try device.makeRenderPipelineState(descriptor: pyrDesc)

        let smpDesc = MTLSamplerDescriptor()
        smpDesc.minFilter = .linear
        smpDesc.magFilter = .linear
        smpDesc.mipFilter = .linear
        smpDesc.sAddressMode = .clampToEdge
        smpDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: smpDesc) else {
            throw LightRendererError.metalUnavailable
        }
        self.sampler = sampler

        guard let uniformBuffer = device.makeBuffer(
                  length: MemoryLayout<GlassUniforms>.stride,
                  options: .storageModeShared
              ),
              let glassBuffer = device.makeBuffer(
                  length: maxGlass * MemoryLayout<Glass>.stride,
                  options: .storageModeShared
              ),
              let lightsBuffer = device.makeBuffer(
                  length: maxGlassLights * MemoryLayout<GlassLight>.stride,
                  options: .storageModeShared
              ) else {
            throw LightRendererError.metalUnavailable
        }
        self.uniformBuffer = uniformBuffer
        self.glassBuffer = glassBuffer
        self.lightsBuffer = lightsBuffer

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
        self.blackTexture = black
    }

    public convenience init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        width: UInt32,
        height: UInt32,
        pixelFormat: MTLPixelFormat = .rgba16Float
    ) throws {
        try self.init(device: device, pixelFormat: pixelFormat)
        try ensurePyramid(width: width, height: height)
    }

    private func ensurePyramid(width: UInt32, height: UInt32) throws {
        let w = max(width, 1)
        let h = max(height, 1)
        if pyramidTexture != nil && self.width == w && self.height == h {
            return
        }
        let halfW = max((w + 1) / 2, 1)
        let halfH = max((h + 1) / 2, 1)
        let maxDim = max(halfW, halfH)
        let mips = min(glassPyramidLevels, UInt32(32 - maxDim.leadingZeroBitCount))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(halfW),
            height: Int(halfH),
            mipmapped: mips > 1
        )
        desc.mipmapLevelCount = Int(mips)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw LightRendererError.metalUnavailable
        }

        var views: [MTLTexture] = []
        views.reserveCapacity(Int(mips))
        for k in 0..<Int(mips) {
            guard let view = tex.makeTextureView(
                pixelFormat: .rgba16Float,
                textureType: .type2D,
                levels: k..<(k + 1),
                slices: 0..<1
            ) else {
                throw LightRendererError.metalUnavailable
            }
            views.append(view)
        }

        self.width = w
        self.height = h
        self.mips = mips
        self.pyramidTexture = tex
        self.pyramidLevelViews = views
    }

    /// Draws `backdrop` with thick refracting `glass` and optional GI `fluence` into `target`.
    public func render(
        commandBuffer: MTLCommandBuffer,
        glass: [Glass],
        lights: [GlassLight] = [],
        settings: GlassSettings = GlassSettings(),
        backdrop: MTLTexture,
        fluence: MTLTexture? = nil,
        target: MTLTexture
    ) throws {
        let w = UInt32(max(target.width, 1))
        let h = UInt32(max(target.height, 1))
        try ensurePyramid(width: w, height: h)

        let ng = min(glass.count, maxGlass)
        let nl = min(lights.count, maxGlassLights)
        if ng > 0 {
            _ = glass.prefix(ng).withUnsafeBytes { raw in
                memcpy(glassBuffer.contents(), raw.baseAddress!, raw.count)
            }
        }
        if nl > 0 {
            _ = lights.prefix(nl).withUnsafeBytes { raw in
                memcpy(lightsBuffer.contents(), raw.baseAddress!, raw.count)
            }
        }

        var uniforms = GlassUniforms()
        uniforms.size = SIMD4<Float>(Float(w), Float(h), Float(ng), Float(nl))
        uniforms.misc = SIMD4<Float>(Float(mips), settings.env, settings.shadow, settings.caustic)
        uniforms.shadow = SIMD4<Float>(settings.shadowOffset.x, settings.shadowOffset.y, settings.shadowBlur, 0.0)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<GlassUniforms>.stride)

        if ng > 0 {
            for k in 0..<Int(mips) {
                let srcTex: MTLTexture = (k == 0) ? backdrop : pyramidLevelViews[k - 1]
                let dstTex = pyramidLevelViews[k]
                let pyrPass = MTLRenderPassDescriptor()
                pyrPass.colorAttachments[0].texture = dstTex
                pyrPass.colorAttachments[0].loadAction = .clear
                pyrPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pyrPass.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pyrPass) {
                    enc.label = "glass pyramid"
                    enc.setRenderPipelineState(pyramidPipeline)
                    enc.setFragmentTexture(srcTex, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
        }

        let mainPass = MTLRenderPassDescriptor()
        mainPass.colorAttachments[0].texture = target
        mainPass.colorAttachments[0].loadAction = .clear
        mainPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mainPass.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: mainPass) {
            enc.label = "glass"
            enc.setRenderPipelineState(mainPipeline)
            enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(glassBuffer, offset: 0, index: 1)
            enc.setFragmentBuffer(lightsBuffer, offset: 0, index: 2)
            enc.setFragmentTexture(backdrop, index: 0)
            enc.setFragmentTexture(pyramidTexture ?? backdrop, index: 1)
            enc.setFragmentTexture(fluence ?? blackTexture, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }
}
#else
public final class GlassRenderer: @unchecked Sendable {
    public init() throws {
        throw LightRendererError.metalUnavailable
    }

    public convenience init(width: UInt32, height: UInt32) throws {
        throw LightRendererError.metalUnavailable
    }
}
#endif
