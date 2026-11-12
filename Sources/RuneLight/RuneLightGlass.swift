import Foundation
#if canImport(Metal)
import Metal
#endif

/// One glass slab, in device px. 96 bytes (`6 × SIMD4<Float>`).
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
        r: SIMD4<Float>,
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

    public func thickness(_ t: Float) -> Glass { var c = self; c.p0.x = t; return c }
    public func bevel(_ b: Float) -> Glass { var c = self; c.p0.y = b; return c }
    public func gap(_ g: Float) -> Glass { var c = self; c.p0.z = g; return c }
    public func dome(_ d: Float) -> Glass { var c = self; c.p0.w = d; return c }
    public func ior(_ n: Float) -> Glass { var c = self; c.p1.x = n; return c }
    public func dispersion(_ d: Float) -> Glass { var c = self; c.p1.y = d; return c }
    public func frost(_ f: Float) -> Glass { var c = self; c.p1.z = f; return c }
    public func presence(_ p: Float) -> Glass { var c = self; c.p1.w = p; return c }
    public func tint(_ absorb: SIMD3<Float>) -> Glass { var c = self; c.tint.x = absorb.x; c.tint.y = absorb.y; c.tint.z = absorb.z; return c }
    public func rimGlow(_ g: Float) -> Glass { var c = self; c.tint.w = g; return c }

    public func union(rect: SIMD4<Float>, radius: Float, k: Float, morph: Float) -> Glass {
        var c = self
        c.b = rect
        c.r.y = radius
        c.r.z = k
        c.r.w = morph
        return c
    }
}

/// 32 bytes (`2 × SIMD4<Float>`).
public struct GlassLight: Sendable, Equatable {
    public var pos: SIMD4<Float>
    public var color: SIMD4<Float>

    public init(pos: SIMD4<Float>, color: SIMD4<Float>) {
        self.pos = pos
        self.color = color
    }

    public static func fromEmitter(_ p: Prim, z: Float, gain: Float) -> GlassLight? {
        guard (p.flags & flagEmissive) != 0 else { return nil }
        let r = 0.5 * sqrtf(p.rect.z * p.rect.w)
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

/// 48 bytes (`3 × SIMD4<Float>`).
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

    public init(device: MTLDevice? = nil, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            throw LightRendererError.metalUnavailable
        }
        self.device = dev
        self.pixelFormat = pixelFormat

        let lib: MTLLibrary
        do {
            lib = try dev.makeLibrary(source: RuneLightShaders.glassShader, options: nil)
        } catch {
            throw LightRendererError.shaderCompileFailed("glass: \(error)")
        }

        guard let vert = lib.makeFunction(name: "glass_vertex"),
              let frag = lib.makeFunction(name: "glass_fragment"),
              let pVert = lib.makeFunction(name: "glass_pyramid_vertex"),
              let pFrag = lib.makeFunction(name: "glass_pyramid_fragment") else {
            throw LightRendererError.shaderCompileFailed("Missing glass entry points")
        }

        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.label = "rune-light-glass"
        mainDesc.vertexFunction = vert
        mainDesc.fragmentFunction = frag
        mainDesc.colorAttachments[0].pixelFormat = pixelFormat
        self.mainPipeline = try dev.makeRenderPipelineState(descriptor: mainDesc)

        let pyrDesc = MTLRenderPipelineDescriptor()
        pyrDesc.label = "rune-light-glass-pyramid"
        pyrDesc.vertexFunction = pVert
        pyrDesc.fragmentFunction = pFrag
        pyrDesc.colorAttachments[0].pixelFormat = .rgba16Float
        self.pyramidPipeline = try dev.makeRenderPipelineState(descriptor: pyrDesc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let smp = dev.makeSamplerState(descriptor: sd) else {
            throw LightRendererError.metalUnavailable
        }
        self.sampler = smp
    }
}
#endif
