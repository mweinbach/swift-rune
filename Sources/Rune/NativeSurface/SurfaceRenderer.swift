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
    public struct Uniforms: Equatable {
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
        #if canImport(CoreVideo) && canImport(IOSurface)
        let token: RetainedPlaneToken?
        #endif
        let revision: UInt64
    }

    private final class PreparedDraw {
        var beforeInstance: UInt32
        var surface: NativeSurface
        var imported: ImportedFrame
        var uniforms: Uniforms
        var uniformBuffer: MTLBuffer?
        var drawn: Bool = false

        init(
            beforeInstance: UInt32,
            surface: NativeSurface,
            imported: ImportedFrame,
            uniforms: Uniforms
        ) {
            self.beforeInstance = beforeInstance
            self.surface = surface
            self.imported = imported
            self.uniforms = uniforms
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

    #if canImport(CoreVideo) && canImport(IOSurface)
    private var importer: CVPixelBufferImporter?
    #endif

    private var cache: [UInt: (surface: NativeSurface, frame: ImportedFrame)] = [:]
    private var draws: [PreparedDraw] = []
    private var activeKeys: Set<UInt> = []
    private var frameSnapshots: [UInt: (frame: NativeSurfaceVideoFrame, mirrored: Bool, revision: UInt64)] = [:]
    private(set) var uniformBufferAllocations = 0

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws {
        self.device = device
        self.primaryFormat = pixelFormat
        self.library = try ShaderLibraryCache.load(
            named: "video",
            source: Self.mslSource,
            requiredFunction: "video_vs",
            on: device
        )

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

    #if canImport(CoreVideo) && canImport(IOSurface)
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
    @discardableResult
    public func prepare(draws inputDraws: [SurfaceDraw], viewport: (UInt32, UInt32)) -> Result<Void, MetalTextureSizeError> {
        activeKeys.removeAll(keepingCapacity: true)
        var count = 0
        defer { frameSnapshots.removeAll(keepingCapacity: true) }

        for d in inputDraws {
            activeKeys.insert(d.surface.key)
            guard d.rect.z > 0 && d.rect.w > 0 else { continue }
            let cacheKey = d.surface.key
            guard let snapshot = frameSnapshots[cacheKey] ?? d.surface.renderSnapshot() else {
                cache.removeValue(forKey: cacheKey)
                continue
            }

            frameSnapshots[cacheKey] = snapshot
            let imported: ImportedFrame
            if let cached = cache[cacheKey]?.frame, cached.revision == snapshot.revision {
                imported = cached
            } else {
                do {
                    imported = try importFrame(snapshot.frame, revision: snapshot.revision)
                    cache[cacheKey] = (d.surface, imported)
                    d.surface.setLastError(nil)
                } catch {
                    d.surface.setLastError("\(error)")
                    cache.removeValue(forKey: cacheKey)
                    if let sizeError = error as? MetalTextureSizeError {
                        draws.removeAll(keepingCapacity: true)
                        return .failure(sizeError)
                    }
                    continue
                }
            }

            let (imageRect, exact) = d.imageGeometry(frame: snapshot.frame)

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
                sampling: SIMD4<Float>(exact ? 1.0 : 0.0, Float(imported.size.0), Float(imported.size.1), snapshot.mirrored ? 1.0 : 0.0),
                orient: SIMD4<Float>(imported.orient.m00, imported.orient.m01, imported.orient.m10, imported.orient.m11),
                clipFade: d.clipFade
            )

            if count < draws.count {
                let slot = draws[count]
                if slot.uniforms != uniforms {
                    // The previous buffer may still be in flight. Moving draws use Metal's
                    // inline copy, so a later prepare cannot overwrite earlier commands.
                    slot.uniformBuffer = nil
                    slot.uniforms = uniforms
                } else if slot.uniformBuffer == nil {
                    // Once geometry settles, even a new video frame can retain this binding.
                    slot.uniformBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<Uniforms>.stride,
                                                           options: .storageModeShared)
                    if slot.uniformBuffer != nil { uniformBufferAllocations += 1 }
                }
                slot.surface = d.surface
                slot.imported = imported
                slot.beforeInstance = d.beforeInstance
                slot.drawn = false
            } else {
                draws.append(PreparedDraw(beforeInstance: d.beforeInstance, surface: d.surface,
                                          imported: imported, uniforms: uniforms))
            }
            count += 1
        }

        if count < draws.count { draws.removeLast(draws.count - count) }
        for key in cache.keys where !activeKeys.contains(key) { cache.removeValue(forKey: key) }
        return .success(())
    }

    /// Encodes surface draw `index` into an already-open Metal render command encoder.
    /// When `targetViewport` is supplied (`(targetW, targetH, originX, originY)`), draws are
    /// reprojected into an isolated layer target without shifting frame-space UVs or clips.
    public func draw(
        encoder: MTLRenderCommandEncoder,
        index: Int,
        pixelFormat: MTLPixelFormat? = nil,
        blend: SurfaceBlend = .sourceOver,
        targetViewport: SIMD4<Float>? = nil
    ) {
        guard index >= 0 && index < draws.count else { return }
        let p = draws[index]
        let fmt = pixelFormat ?? primaryFormat
        guard let pipe = try? pipeline(for: fmt, blend: blend) else { return }
        encoder.setRenderPipelineState(pipe)
        if targetViewport == nil, let buffer = p.uniformBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        } else {
            var u = p.uniforms
            if let targetViewport { u.viewport = targetViewport }
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
        encoder.setFragmentTexture(p.imported.textures[0], index: 0)
        encoder.setFragmentTexture(p.imported.textures[1], index: 1)
        encoder.setFragmentSamplerState(samplerLinear, index: 0)
        encoder.setFragmentSamplerState(samplerNearest, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        p.drawn = true
    }

    /// Attaches retention tokens and submission/completion timing reporters to `commandBuffer`,
    /// mirroring `SurfaceRenderer::submit` so observers fire with `submittedAt`, `completedAt`,
    /// and GPU start/end timestamps, while imported planes remain alive until GPU completion.
    public func trackSubmission(commandBuffer: MTLCommandBuffer) {
        let drawnDraws = draws.filter { $0.drawn }
        guard !drawnDraws.isEmpty else { return }

        let submittedAt = ContinuousClock.now
        var heldTextures: [MTLTexture] = []
        #if canImport(CoreVideo) && canImport(IOSurface)
        var heldTokens: [RetainedPlaneToken] = []
        #endif
        var reporters: [(NativeSurface, FrameTiming)] = []

        for p in drawnDraws {
            heldTextures.append(contentsOf: p.imported.textures)
            #if canImport(CoreVideo) && canImport(IOSurface)
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

        #if canImport(CoreVideo) && canImport(IOSurface)
        let capturedTokens = heldTokens
        #endif
        let capturedTextures = heldTextures
        let immutableReporters = reporters
        commandBuffer.addCompletedHandler { cb in
            withExtendedLifetime(capturedTextures) {}
            #if canImport(CoreVideo) && canImport(IOSurface)
            withExtendedLifetime(capturedTokens) {}
            #endif
            guard cb.status == .completed else { return }
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

    private func importFrame(_ frame: NativeSurfaceVideoFrame, revision: UInt64) throws -> ImportedFrame {
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
            #if canImport(CoreVideo) && canImport(IOSurface)
            return ImportedFrame(
                frameId: frame.id,
                size: frame.size,
                format: frame.format,
                color: frame.color,
                orient: frame.orient,
                textures: [tex0, tex1],
                token: nil,
                revision: revision
            )
            #else
            return ImportedFrame(
                frameId: frame.id,
                size: frame.size,
                format: frame.format,
                color: frame.color,
                orient: frame.orient,
                textures: [tex0, tex1],
                revision: revision
            )
            #endif
        #if canImport(CoreVideo) && canImport(IOSurface)
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
                revision: revision
            )
        #endif
        }
    }

    private func uploadTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat, bytesPerRow: Int, data: Data) throws -> MTLTexture {
        try MetalTextureLimits.validate(width: width, height: height, resource: "surface plane", on: device)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
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

    internal static let mslSource = """
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
        float2 local = px - u.viewport.zw;
        float2 ndc = float2(
            (local.x / max(1.0, u.viewport.x)) * 2.0 - 1.0,
            1.0 - (local.y / max(1.0, u.viewport.y)) * 2.0
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

    static inline float4 convert_video_sample(
        float4 a,
        float2 uvRaw,
        constant VideoUniforms &u
    ) {
        float fmt = u.color.x;
        float3 rgb;
        float alpha = 1.0;
        if (fmt < 0.5) {
            rgb = a.rgb;
            alpha = a.a;
        } else {
            float y = a.r;
            float2 c = uvRaw - float2(128.0 / 255.0);
            if (fmt < 1.5) {
                y = (y - (16.0 / 255.0)) * (255.0 / 219.0);
                c *= (255.0 / 224.0);
            }
            rgb = clamp(yuv_to_rgb(y, c.x, c.y, u.color.y), 0.0, 1.0);
        }
        float3 lin = apply_transfer(rgb, u.color.z);
        return float4(lin * alpha, alpha);
    }

    static inline float4 sample_linear_video(
        float2 uv,
        constant VideoUniforms &u,
        texture2d<float> plane0,
        texture2d<float> plane1,
        sampler sampLinear
    ) {
        float4 p0 = plane0.sample(sampLinear, uv, level(0.0));
        float2 p1 = (u.color.x >= 0.5) ? plane1.sample(sampLinear, uv, level(0.0)).rg : float2(0.5);
        return convert_video_sample(p0, p1, u);
    }

    fragment float4 video_fs(
        VideoOut in [[stage_in]],
        constant VideoUniforms &u [[buffer(0)]],
        texture2d<float> plane0 [[texture(0)]],
        texture2d<float> plane1 [[texture(1)]],
        sampler sampLinear [[sampler(0)]],
        sampler sampNearest [[sampler(1)]]
    ) {
        float2 frag = in.pos.xy + u.viewport.zw;
        float2 local = frag - u.image.xy;
        float2 unflipped = local / max(u.image.zw, float2(1.0));
        if (unflipped.x < 0.0 || unflipped.x >= 1.0 || unflipped.y < 0.0 || unflipped.y >= 1.0) {
            discard_fragment();
        }
        if (u.sampling.w > 0.5) {
            local.x = u.image.z - local.x;
        }
        float2 col0 = float2(u.orient.x, u.orient.z);
        float2 col1 = float2(u.orient.y, u.orient.w);
        float2 size = abs(col0) * u.image.z + abs(col1) * u.image.w;
        float2 d = local - u.image.zw * 0.5;
        float2 buffer = float2(u.orient.x * d.x + u.orient.y * d.y, u.orient.z * d.x + u.orient.w * d.y) + size * 0.5;
        float2 uv = buffer / max(size, float2(1.0));

        float4 texel;
        if (u.sampling.x > 0.5) {
            int2 maxTex = int2(max(float2(1.0), u.sampling.yz)) - 1;
            int2 texelCoord = clamp(int2(floor(buffer)), int2(0), maxTex);
            float4 p0 = plane0.read(uint2(texelCoord), 0);
            float2 p1 = (u.color.x >= 0.5) ? plane1.read(uint2(texelCoord / 2), 0).rg : float2(0.5);
            texel = convert_video_sample(p0, p1, u);
        } else {
            float2 ratio = u.sampling.yz / max(size, float2(1.0));
            int2 taps = clamp(int2(ceil(ratio)), int2(1), int2(8));
            texel = float4(0.0);
            for (int iy = 0; iy < taps.y; ++iy) {
                for (int ix = 0; ix < taps.x; ++ix) {
                    float2 offset = (float2(float(ix) + 0.5, float(iy) + 0.5) / float2(taps) - 0.5) / max(size, float2(1.0));
                    texel += sample_linear_video(uv + offset, u, plane0, plane1, sampLinear);
                }
            }
            texel /= float(taps.x * taps.y);
        }

        float cov = clip_alpha(frag, u.clip, u.clipFade);
        if (cov <= 0.0) return float4(0.0);

        if (u.fade.z != 0.0) {
            float fd = dot(frag - u.fadeOrigin.xy, u.fade.xy) * u.fade.z;
            cov *= u.fade.w + (1.0 - u.fade.w) * saturate(fd);
            if (cov <= 0.0) return float4(0.0);
        }

        float2 nodeCenter = u.node.xy + u.node.zw * 0.5;
        float2 nodeHalf = u.node.zw * 0.5;
        float dBox = sd_rounded_box(frag - nodeCenter, nodeHalf, u.radii);
        cov *= saturate(0.5 - dBox);
        if (cov <= 0.0) return float4(0.0);

        float mask = cov * u.color.w;
        return texel * mask;
    }
    """
}
#endif
