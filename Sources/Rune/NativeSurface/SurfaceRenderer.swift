import Foundation

#if canImport(Metal)
@preconcurrency import Metal
#if canImport(simd)
import simd
#endif

/// Blend mode supported by `SurfaceRenderer`.
public enum SurfaceBlend: UInt8, Sendable, Equatable {
    case sourceOver
    case plusLighter
}

/// GPU surface/video renderer translating `native_surface/video.wgsl` 1:1 to Metal (`rune::native_surface::SurfaceRenderer`).
public final class SurfaceRenderer: @unchecked Sendable {
    public struct Uniforms {
        public var viewport: SIMD4<Float>
        public var node: SIMD4<Float>
        public var image: SIMD4<Float>
        public var radii: SIMD4<Float>
        public var clip: SIMD4<Float>
        public var fade: SIMD4<Float>
        public var fadeOrigin: SIMD4<Float> // (ox, oy, opacity, reserved)
        public var color: SIMD4<Float>      // (format, matrix, transfer, alphaMult)
        public var sampling: SIMD4<Float>   // (oneToOne, srcW, srcH, mirrored)
        public var orient: SIMD4<Float>     // (m00, m01, m10, m11)
        public var clipFade: SIMD4<UInt32>  // packed clip.wgsl fade/round-clip
    }

    private struct ImportedFrame {
        let frameId: UInt64
        let size: (UInt32, UInt32)
        let format: SurfacePixelFormat
        let color: SurfaceColorInfo
        let orient: Orient
        let textures: [MTLTexture] // [plane0, plane1]
        #if os(macOS)
        let token: RetainedPlaneToken?
        #endif
        let objectId: UInt64
    }

    private final class PreparedDraw {
        var beforeInstance: UInt32
        let surface: NativeSurface
        var imported: ImportedFrame
        var uniforms: Uniforms
        var uniformBuffer: MTLBuffer
        var drawn: Bool = false

        init(
            beforeInstance: UInt32,
            surface: NativeSurface,
            imported: ImportedFrame,
            uniforms: Uniforms,
            uniformBuffer: MTLBuffer
        ) {
            self.beforeInstance = beforeInstance
            self.surface = surface
            self.imported = imported
            self.uniforms = uniforms
            self.uniformBuffer = uniformBuffer
        }
    }

    public let device: MTLDevice
    public let primaryFormat: MTLPixelFormat
    public var srgbBlend: Bool = false

    private let library: MTLLibrary
    private let samplerLinear: MTLSamplerState
    private let samplerNearest: MTLSamplerState
    private var pipelinesSourceOver: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var pipelinesAdditive: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    #if os(macOS)
    private var importer: CVPixelBufferImporter?
    #endif

    private var cache: [UInt: ImportedFrame] = [:]
    private var draws: [PreparedDraw] = []

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws {
        self.device = device
        self.primaryFormat = pixelFormat
        self.library = try device.makeLibrary(source: Self.mslSource, options: nil)

        let linDesc = MTLSamplerDescriptor()
        linDesc.minFilter = .linear
        linDesc.magFilter = .linear
        linDesc.sAddressMode = .clampToEdge
        linDesc.tAddressMode = .clampToEdge
        guard let lin = device.makeSamplerState(descriptor: linDesc) else {
            throw NativeSurfaceError.importFailed("failed to create linear sampler")
        }
        self.samplerLinear = lin

        let nearDesc = MTLSamplerDescriptor()
        nearDesc.minFilter = .nearest
        nearDesc.magFilter = .nearest
        nearDesc.sAddressMode = .clampToEdge
        nearDesc.tAddressMode = .clampToEdge
        guard let near = device.makeSamplerState(descriptor: nearDesc) else {
            throw NativeSurfaceError.importFailed("failed to create nearest sampler")
        }
        self.samplerNearest = near

        _ = try pipeline(for: pixelFormat, blend: .sourceOver)
    }

    public var count: Int { draws.count }
    public var isEmpty: Bool { draws.isEmpty }

    #if os(macOS)
    public var livePlanes: Int {
        importer?.livePlanes ?? 0
    }
    #endif

    public func beforeInstance(at index: Int) -> UInt32 {
        draws[index].beforeInstance
    }

    public func ensureFormat(_ pixelFormat: MTLPixelFormat, blend: SurfaceBlend = .sourceOver) throws {
        _ = try pipeline(for: pixelFormat, blend: blend)
    }

    private func pipeline(for pixelFormat: MTLPixelFormat, blend: SurfaceBlend) throws -> MTLRenderPipelineState {
        switch blend {
        case .sourceOver:
            if let existing = pipelinesSourceOver[pixelFormat] { return existing }
            let p = try buildPipeline(pixelFormat: pixelFormat, additive: false)
            pipelinesSourceOver[pixelFormat] = p
            return p
        case .plusLighter:
            if let existing = pipelinesAdditive[pixelFormat] { return existing }
            let p = try buildPipeline(pixelFormat: pixelFormat, additive: true)
            pipelinesAdditive[pixelFormat] = p
            return p
        }
    }

    private func buildPipeline(pixelFormat: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
        guard let vs = library.makeFunction(name: "video_vs"),
              let fs = library.makeFunction(name: "video_fs") else {
            throw NativeSurfaceError.importFailed("missing video_vs / video_fs in Metal library")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        let att = desc.colorAttachments[0]!
        att.pixelFormat = pixelFormat
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one
        att.sourceAlphaBlendFactor = .one
        if additive {
            att.destinationRGBBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
        } else {
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    /// Latches the current picture for each surface draw and prepares GPU textures + uniforms.
    public func prepare(draws inputDraws: [SurfaceDraw], viewport: (UInt32, UInt32)) {
        let activeKeys = Set(inputDraws.map { $0.surface.key })
        cache = cache.filter { activeKeys.contains($0.key) }

        var prepared: [PreparedDraw] = []
        prepared.reserveCapacity(inputDraws.count)

        for d in inputDraws {
            guard d.rect.z > 0 && d.rect.w > 0 else { continue }
            guard let (frame, mirrored) = d.surface.latestMirrored() else {
                cache.removeValue(forKey: d.surface.key)
                continue
            }

            let cacheKey = d.surface.key
            let frameSig = Self.frameSignature(frame)
            let imported: ImportedFrame
            if let cached = cache[cacheKey], cached.objectId == frameSig {
                imported = cached
            } else {
                do {
                    imported = try importFrame(frame, signature: frameSig)
                    cache[cacheKey] = imported
                    d.surface.setLastError(nil)
                } catch {
                    d.surface.setLastError("\(error)")
                    cache.removeValue(forKey: cacheKey)
                    continue
                }
            }

            let upright = imported.orient.upright(width: imported.size.0, height: imported.size.1)
            let imageRect = d.surface.place.imageRect(forNode: d.rect, imageSize: upright, fit: d.fit)
            let exact = abs(imageRect.z - Float(upright.0)) < 0.001
                && abs(imageRect.w - Float(upright.1)) < 0.001
                && abs(imageRect.x - imageRect.x.rounded()) < 0.001
                && abs(imageRect.y - imageRect.y.rounded()) < 0.001

            let fmtCode: Float
            switch imported.format {
            case .bgra, .rgba: fmtCode = 0.0
            case .nv12Video: fmtCode = 1.0
            case .nv12Full: fmtCode = 2.0
            }
            let matrixCode: Float = (imported.color.matrix == .bt709) ? 1.0 : 0.0
            let transferCode: Float
            if srgbBlend {
                transferCode = 2.0
            } else {
                switch imported.color.transfer {
                case .srgb: transferCode = 0.0
                case .bt709: transferCode = 1.0
                case .linear: transferCode = 2.0
                }
            }

            var uniforms = Uniforms(
                viewport: SIMD4<Float>(Float(viewport.0), Float(viewport.1), 0, 0),
                node: d.rect,
                image: imageRect,
                radii: d.radii,
                clip: d.clip,
                fade: d.fade,
                fadeOrigin: SIMD4<Float>(d.fadeOrigin.x, d.fadeOrigin.y, d.opacity, 0),
                color: SIMD4<Float>(fmtCode, matrixCode, transferCode, d.opacity),
                sampling: SIMD4<Float>(exact ? 1.0 : 0.0, Float(imported.size.0), Float(imported.size.1), mirrored ? 1.0 : 0.0),
                orient: SIMD4<Float>(imported.orient.m00, imported.orient.m01, imported.orient.m10, imported.orient.m11),
                clipFade: d.clipFade
            )

            guard let uBuf = device.makeBuffer(
                bytes: &uniforms,
                length: MemoryLayout<Uniforms>.stride,
                options: .storageModeShared
            ) else {
                continue
            }

            prepared.append(PreparedDraw(
                beforeInstance: d.beforeInstance,
                surface: d.surface,
                imported: imported,
                uniforms: uniforms,
                uniformBuffer: uBuf
            ))
        }

        self.draws = prepared
    }

    /// Encodes surface draw `index` into an already-open Metal render command encoder.
    public func draw(
        encoder: MTLRenderCommandEncoder,
        index: Int,
        pixelFormat: MTLPixelFormat? = nil,
        blend: SurfaceBlend = .sourceOver
    ) {
        guard index >= 0 && index < draws.count else { return }
        let p = draws[index]
        p.drawn = true
        let fmt = pixelFormat ?? primaryFormat
        guard let pipe = try? pipeline(for: fmt, blend: blend) else { return }
        encoder.setRenderPipelineState(pipe)
        encoder.setVertexBuffer(p.uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(p.uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(p.imported.textures[0], index: 0)
        encoder.setFragmentTexture(p.imported.textures[1], index: 1)
        encoder.setFragmentSamplerState(samplerLinear, index: 0)
        encoder.setFragmentSamplerState(samplerNearest, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Attaches retention tokens and submission/completion timing reporters to `commandBuffer`,
    /// mirroring `SurfaceRenderer::submit` so observers fire with `submittedAt`, `completedAt`,
    /// and GPU start/end timestamps, while imported planes remain alive until GPU completion.
    public func trackSubmission(commandBuffer: MTLCommandBuffer) {
        let drawnDraws = draws.filter { $0.drawn }
        guard !drawnDraws.isEmpty else { return }

        let submittedAt = ContinuousClock.now
        var heldTextures: [MTLTexture] = []
        #if os(macOS)
        var heldTokens: [RetainedPlaneToken] = []
        #endif
        var reporters: [(NativeSurface, FrameTiming)] = []

        for p in drawnDraws {
            heldTextures.append(contentsOf: p.imported.textures)
            #if os(macOS)
            if let tok = p.imported.token {
                heldTokens.append(tok)
            }
            #endif
            let timing = FrameTiming(frameId: p.imported.frameId, submittedAt: submittedAt)
            reporters.append((p.surface, timing))
        }

        // Notify initial submission before installing completion handler.
        for (surface, timing) in reporters {
            surface.report(timing)
        }

        #if os(macOS)
        let capturedTokens = heldTokens
        #endif
        let capturedTextures = heldTextures
        let immutableReporters = reporters
        commandBuffer.addCompletedHandler { cb in
            withExtendedLifetime(capturedTextures) {}
            #if os(macOS)
            withExtendedLifetime(capturedTokens) {}
            #endif
            let completedAt = ContinuousClock.now
            let gStart: Double? = cb.gpuStartTime > 0 ? cb.gpuStartTime : nil
            let gEnd: Double? = (cb.gpuEndTime >= cb.gpuStartTime && cb.gpuEndTime > 0) ? cb.gpuEndTime : nil
            for (surface, var timing) in immutableReporters {
                timing.completedAt = completedAt
                timing.gpuStartSeconds = gStart
                timing.gpuEndSeconds = gEnd
                surface.report(timing)
            }
        }
    }

    private static func frameSignature(_ frame: NativeSurfaceVideoFrame) -> UInt64 {
        var h = Hasher()
        h.combine(frame.id)
        h.combine(frame.size.0)
        h.combine(frame.size.1)
        h.combine(frame.format)
        h.combine(frame.color)
        h.combine(frame.orient)
        switch frame.source {
        case .bytes(let b):
            h.combine(0 as UInt8)
            h.combine(b.planes.count)
        #if os(macOS)
        case .pixelBuffer(let pb):
            h.combine(1 as UInt8)
            h.combine(ObjectIdentifier(pb))
        #endif
        }
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    private func importFrame(_ frame: NativeSurfaceVideoFrame, signature: UInt64) throws -> ImportedFrame {
        switch frame.source {
        case .bytes(let bf):
            let tex0Fmt: MTLPixelFormat
            switch bf.format {
            case .bgra: tex0Fmt = .bgra8Unorm
            case .rgba: tex0Fmt = .rgba8Unorm
            case .nv12Video, .nv12Full: tex0Fmt = .r8Unorm
            }
            let bpr0 = (bf.format == .bgra || bf.format == .rgba) ? Int(bf.width) * 4 : Int(bf.width)
            let tex0 = try uploadTexture(width: Int(bf.width), height: Int(bf.height), pixelFormat: tex0Fmt, bytesPerRow: bpr0, data: bf.planes[0])
            let tex1: MTLTexture
            if bf.format == .bgra || bf.format == .rgba {
                tex1 = tex0
            } else {
                tex1 = try uploadTexture(width: Int(bf.width) / 2, height: Int(bf.height) / 2, pixelFormat: .rg8Unorm, bytesPerRow: Int(bf.width), data: bf.planes[1])
            }
            #if os(macOS)
            return ImportedFrame(
                frameId: frame.id,
                size: frame.size,
                format: frame.format,
                color: frame.color,
                orient: frame.orient,
                textures: [tex0, tex1],
                token: nil,
                objectId: signature
            )
            #else
            return ImportedFrame(
                frameId: frame.id,
                size: frame.size,
                format: frame.format,
                color: frame.color,
                orient: frame.orient,
                textures: [tex0, tex1],
                objectId: signature
            )
            #endif
        #if os(macOS)
        case .pixelBuffer(let pb):
            if importer == nil {
                importer = try CVPixelBufferImporter(device: device)
            }
            let (textures, token) = try autoreleasepool {
                try importer!.import(pb, format: frame.format, size: frame.size)
            }
            return ImportedFrame(
                frameId: frame.id,
                size: frame.size,
                format: frame.format,
                color: frame.color,
                orient: frame.orient,
                textures: textures,
                token: token,
                objectId: signature
            )
        #endif
        }
    }

    private func uploadTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat, bytesPerRow: Int, data: Data) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw NativeSurfaceError.importFailed("makeTexture \(width)x\(height) failed")
        }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                tex.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
        }
        return tex
    }

    // MARK: - Faithful translation of `crates/rune/src/native_surface/video.wgsl`

    private static let mslSource = """
    #include <metal_stdlib>
    using namespace metal;

    \(RenderShaders.clipMSL)

    struct VideoUniforms {
        float4 viewport;
        float4 node;
        float4 image;
        float4 radii;
        float4 clip;
        float4 fade;
        float4 fadeOrigin; // (ox, oy, opacity, reserved)
        float4 color;      // (format, matrix, transfer, opacity)
        float4 sampling;   // (oneToOne, srcW, srcH, mirrored)
        float4 orient;     // (m00, m01, m10, m11)
        uint4 clipFade;
    };

    struct VideoOut {
        float4 pos [[position]];
    };

    vertex VideoOut video_vs(
        uint vid [[vertex_id]],
        constant VideoUniforms &u [[buffer(0)]]
    ) {
        float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
        float2 px = u.node.xy + corner * u.node.zw;
        float2 ndc = float2(
            (px.x / max(1.0, u.viewport.x)) * 2.0 - 1.0,
            1.0 - (px.y / max(1.0, u.viewport.y)) * 2.0
        );
        VideoOut out;
        out.pos = float4(ndc, 0.0, 1.0);
        return out;
    }

    static inline float sd_rounded_box(float2 p, float2 halfSize, float4 r) {
        float rr = (p.x > 0.0) ? ((p.y > 0.0) ? r.z : r.y) : ((p.y > 0.0) ? r.w : r.x);
        float cr = min(max(0.0, abs(rr)), min(halfSize.x, halfSize.y));
        float2 q = abs(p) - halfSize + cr;
        if (rr < 0.0) {
            return max(max(q.x, q.y), (q.x + q.y + 0.41421356 * cr) * 0.70710678);
        }
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - cr;
    }

    static inline float transfer_srgb(float c) {
        return (c <= 0.04045) ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4);
    }

    static inline float transfer_bt709(float c) {
        return (c < 0.081) ? (c / 4.5) : pow((c + 0.099) / 1.099, 1.0 / 0.45);
    }

    static inline float3 apply_transfer(float3 c, float mode) {
        if (mode > 1.5) return c;
        if (mode > 0.5) {
            return float3(transfer_bt709(c.x), transfer_bt709(c.y), transfer_bt709(c.z));
        }
        return float3(transfer_srgb(c.x), transfer_srgb(c.y), transfer_srgb(c.z));
    }

    static inline float3 yuv_to_rgb(float y, float cb, float cr, float matrix) {
        if (matrix > 0.5) {
            // BT.709
            return float3(
                y + 1.5748 * cr,
                y - 0.187324 * cb - 0.468124 * cr,
                y + 1.8556 * cb
            );
        }
        // BT.601
        return float3(
            y + 1.402 * cr,
            y - 0.344136 * cb - 0.714136 * cr,
            y + 1.772 * cb
        );
    }

    static inline float4 sample_plane_color(
        float2 px,
        constant VideoUniforms &u,
        texture2d<float> plane0,
        texture2d<float> plane1,
        sampler sampLinear,
        sampler sampNearest,
        bool exactMode
    ) {
        float2 norm = (px - u.image.xy) / u.image.zw;
        if (norm.x < 0.0 || norm.x >= 1.0 || norm.y < 0.0 || norm.y >= 1.0) {
            return float4(0.0);
        }
        if (u.sampling.w > 0.5) {
            norm.x = 1.0 - norm.x;
        }
        float2 c = norm - 0.5;
        float2 uv = float2(
            u.orient.x * c.x + u.orient.y * c.y,
            u.orient.z * c.x + u.orient.w * c.y
        ) + 0.5;
        if (exactMode) {
            float2 srcSz = u.sampling.yz;
            uv = (floor(clamp(uv, 0.0, 0.999999) * srcSz) + 0.5) / srcSz;
        }

        float fmt = u.color.x;
        float3 rgb;
        float a = 1.0;
        if (fmt < 0.5) {
            float4 bgra = exactMode
                ? plane0.sample(sampNearest, uv)
                : plane0.sample(sampLinear, uv);
            rgb = bgra.rgb;
            a = bgra.a;
        } else {
            float yRaw = exactMode
                ? plane0.sample(sampNearest, uv).r
                : plane0.sample(sampLinear, uv).r;
            float2 uvRaw = exactMode
                ? plane1.sample(sampLinear, uv).rg
                : plane1.sample(sampLinear, uv).rg;
            float y;
            float cb;
            float cr;
            if (fmt < 1.5) {
                // NV12 video range [16..235] / [16..240]
                y = (yRaw - (16.0 / 255.0)) * (255.0 / 219.0);
                cb = (uvRaw.x - (128.0 / 255.0)) * (255.0 / 224.0);
                cr = (uvRaw.y - (128.0 / 255.0)) * (255.0 / 224.0);
            } else {
                // NV12 full range
                y = yRaw;
                cb = uvRaw.x - (128.0 / 255.0);
                cr = uvRaw.y - (128.0 / 255.0);
            }
            rgb = clamp(yuv_to_rgb(y, cb, cr, u.color.y), 0.0, 1.0);
        }

        float3 lin = apply_transfer(rgb, u.color.z);
        return float4(lin * a, a);
    }

    fragment float4 video_fs(
        VideoOut in [[stage_in]],
        constant VideoUniforms &u [[buffer(0)]],
        texture2d<float> plane0 [[texture(0)]],
        texture2d<float> plane1 [[texture(1)]],
        sampler sampLinear [[sampler(0)]],
        sampler sampNearest [[sampler(1)]]
    ) {
        float2 frag = in.pos.xy;
        float cov = 1.0;
        if (any(u.clipFade != uint4(0u))) {
            cov = clip_alpha(frag, u.clip, u.clipFade);
            if (cov <= 0.0) return float4(0.0);
        } else {
            if (u.clip.z <= 0.0 || u.clip.w <= 0.0) return float4(0.0);
            float clipX = saturate(min(frag.x - u.clip.x + 0.5, (u.clip.x + u.clip.z) - frag.x + 0.5));
            float clipY = saturate(min(frag.y - u.clip.y + 0.5, (u.clip.y + u.clip.w) - frag.y + 0.5));
            cov = clipX * clipY;
            if (cov <= 0.0) return float4(0.0);

            if (u.fade.z != 0.0) {
                float d = dot(frag - u.fadeOrigin.xy, u.fade.xy) * u.fade.z;
                cov *= u.fade.w + (1.0 - u.fade.w) * saturate(d);
                if (cov <= 0.0) return float4(0.0);
            }
        }

        float2 nodeCenter = u.node.xy + u.node.zw * 0.5;
        float2 nodeHalf = u.node.zw * 0.5;
        float dBox = sd_rounded_box(frag - nodeCenter, nodeHalf, u.radii);
        float nodeCov = saturate(0.5 - dBox);
        cov *= nodeCov;
        if (cov <= 0.0) return float4(0.0);

        float4 texel;
        if (u.sampling.x > 0.5) {
            texel = sample_plane_color(frag, u, plane0, plane1, sampLinear, sampNearest, true);
        } else {
            // 8x8 linear-light area supersampling across the output pixel footprint.
            float4 acc = float4(0.0);
            for (int iy = 0; iy < 8; ++iy) {
                float oy = -0.5 + (float(iy) + 0.5) * 0.125;
                for (int ix = 0; ix < 8; ++ix) {
                    float ox = -0.5 + (float(ix) + 0.5) * 0.125;
                    acc += sample_plane_color(frag + float2(ox, oy), u, plane0, plane1, sampLinear, sampNearest, false);
                }
            }
            texel = acc * (1.0 / 64.0);
        }

        float mask = cov * u.color.w;
        return texel * mask;
    }
    """
}
#endif
