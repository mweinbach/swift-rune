import Foundation
import RuneRef
#if canImport(simd)
import simd
#endif

#if canImport(Metal) && canImport(QuartzCore)
@preconcurrency import Metal
import QuartzCore

/// Upstream-parity GPU rendering engine for `RenderFrame` (`render.rs` + `pass.rs` + `layers.rs` + `backdrop_blur.rs` + `layer_blur.rs`).
internal final class RenderFrameEngine {
    let device: MTLDevice

    // Main uber-shader pipelines (`vs` and `vs_springs`) across pixel formats & blend modes
    let uberVert: MTLFunction
    let uberVertSprings: MTLFunction
    let uberFrag: MTLFunction

    let pipelineSRGB: MTLRenderPipelineState
    let pipelineGamma: MTLRenderPipelineState
    var pipelineFloat: MTLRenderPipelineState?
    var pipelineAddSRGB: MTLRenderPipelineState?
    var pipelineAddGamma: MTLRenderPipelineState?
    var pipelineAddFloat: MTLRenderPipelineState?

    let pipelineSpringsSRGB: MTLRenderPipelineState
    let pipelineSpringsGamma: MTLRenderPipelineState
    var pipelineSpringsFloat: MTLRenderPipelineState?
    var pipelineSpringsAddSRGB: MTLRenderPipelineState?
    var pipelineSpringsAddGamma: MTLRenderPipelineState?
    var pipelineSpringsAddFloat: MTLRenderPipelineState?
    private struct ExtraPipelineKey: Hashable {
        let formatRawValue: UInt
        let additive: Bool
        let springs: Bool
    }
    private var extraPipelines: [ExtraPipelineKey: MTLRenderPipelineState] = [:]
    fileprivate var layersPreparedState: (instances: [RenderInstance], tracker: ResidentLayerTracker?, width: Int, height: Int, revision: UInt64)?

    var layerBlur: LayerBlurPipeline?
    let backdropBlur: BackdropBlurPass
    let layersPool: LayersPool = LayersPool()
    let uploader: AtlasUploader = AtlasUploader()
    let breakers: PipelineBreakers = PipelineBreakers()
    let gpuLoss: GpuDeviceTracker

    struct BackdropEntry {
        let format: MTLPixelFormat
        let texture: MTLTexture
    }

    var springBindings: GPUSpringBindings?
    var springTimeSeconds: Double = 0
    var backdrops: [BackdropEntry] = []
    var currentFormat: MTLPixelFormat = .bgra8Unorm_srgb
    var hasExplicitFormat: Bool = false
    var extraFormats: [MTLPixelFormat] = []
    var lastViewportSize: (Int, Int) = (0, 0)

    var hasCompiledShaders: Bool {
        _ = (pipelineSRGB, pipelineSpringsSRGB, backdropBlur)
        return true
    }

    init(device: MTLDevice) throws {
        self.device = device
        self.gpuLoss = GpuDeviceTracker(device: device)
        let lib: MTLLibrary
        do {
            lib = try ShaderLibraryCache.load(
                named: "shader",
                source: RenderShaders.shaderMSL,
                requiredFunction: "vs_springs",
                on: device
            )
        } catch {
            throw MetalRenderer.RendererError.shaderCompileFailed("RenderShaders.shaderMSL: \(error)")
        }

        guard let vs = lib.makeFunction(name: "vs"),
              let vsSprings = lib.makeFunction(name: "vs_springs"),
              let fs = lib.makeFunction(name: "fs") else {
            throw MetalRenderer.RendererError.shaderCompileFailed("Missing vs/vs_springs/fs in RenderShaders.shaderMSL")
        }

        self.uberVert = vs
        self.uberVertSprings = vsSprings
        self.uberFrag = fs

        self.pipelineSRGB = try Self.makePipeline(device: device, vert: vs, frag: fs, format: .bgra8Unorm_srgb, additive: false)
        self.pipelineGamma = try Self.makePipeline(device: device, vert: vs, frag: fs, format: .bgra8Unorm, additive: false)
        self.pipelineSpringsSRGB = try Self.makePipeline(device: device, vert: vsSprings, frag: fs, format: .bgra8Unorm_srgb, additive: false)
        self.pipelineSpringsGamma = try Self.makePipeline(device: device, vert: vsSprings, frag: fs, format: .bgra8Unorm, additive: false)

        do {
            self.backdropBlur = try BackdropBlurPass(device: device)
        } catch {
            throw MetalRenderer.RendererError.shaderCompileFailed("Sub-pass compilation failed: \(error)")
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        vert: MTLFunction,
        frag: MTLFunction,
        format: MTLPixelFormat,
        additive: Bool
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vert
        desc.fragmentFunction = frag
        let att = desc.colorAttachments[0]!
        att.pixelFormat = format
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one
        att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private func dropFeature(_ feature: BreakerFeature) {
        switch feature {
        case .isolation:
            pipelineFloat = nil
            pipelineSpringsFloat = nil
        case .plusLighter:
            pipelineAddSRGB = nil
            pipelineAddGamma = nil
            pipelineAddFloat = nil
            pipelineSpringsAddSRGB = nil
            pipelineSpringsAddGamma = nil
            pipelineSpringsAddFloat = nil
        case .layerBlur:
            layerBlur = nil
        }
    }

    private static func failRealMetalBuildForTesting(device: MTLDevice, feature: BreakerFeature) throws -> Never {
        _ = try device.makeLibrary(source: "invalid_msl_for_\(feature.rawValue) { return ;", options: nil)
        throw MetalRenderer.RendererError.shaderCompileFailed("Forced build failure for \(feature.rawValue)")
    }

    private func ensureIsolationPipelines() throws -> Bool {
        let forceInvalid = breakers.shouldForceBuildFailureForTesting(.isolation)
        if !forceInvalid, pipelineFloat != nil, pipelineSpringsFloat != nil {
            return true
        }
        do {
            if forceInvalid {
                try Self.failRealMetalBuildForTesting(device: device, feature: .isolation)
            }
            let pf = try Self.makePipeline(device: device, vert: uberVert, frag: uberFrag, format: .rgba16Float, additive: false)
            let psf = try Self.makePipeline(device: device, vert: uberVertSprings, frag: uberFrag, format: .rgba16Float, additive: false)
            self.pipelineFloat = pf
            self.pipelineSpringsFloat = psf
            return true
        } catch {
            dropFeature(.isolation)
            throw error
        }
    }

    private func ensurePlusLighterPipelines() throws -> Bool {
        let forceInvalid = breakers.shouldForceBuildFailureForTesting(.plusLighter)
        if !forceInvalid,
           pipelineAddSRGB != nil, pipelineAddGamma != nil, pipelineAddFloat != nil,
           pipelineSpringsAddSRGB != nil, pipelineSpringsAddGamma != nil, pipelineSpringsAddFloat != nil {
            return true
        }
        do {
            if forceInvalid {
                try Self.failRealMetalBuildForTesting(device: device, feature: .plusLighter)
            }
            let p1 = try Self.makePipeline(device: device, vert: uberVert, frag: uberFrag, format: .bgra8Unorm_srgb, additive: true)
            let p2 = try Self.makePipeline(device: device, vert: uberVert, frag: uberFrag, format: .bgra8Unorm, additive: true)
            let p3 = try Self.makePipeline(device: device, vert: uberVert, frag: uberFrag, format: .rgba16Float, additive: true)
            let p4 = try Self.makePipeline(device: device, vert: uberVertSprings, frag: uberFrag, format: .bgra8Unorm_srgb, additive: true)
            let p5 = try Self.makePipeline(device: device, vert: uberVertSprings, frag: uberFrag, format: .bgra8Unorm, additive: true)
            let p6 = try Self.makePipeline(device: device, vert: uberVertSprings, frag: uberFrag, format: .rgba16Float, additive: true)
            self.pipelineAddSRGB = p1
            self.pipelineAddGamma = p2
            self.pipelineAddFloat = p3
            self.pipelineSpringsAddSRGB = p4
            self.pipelineSpringsAddGamma = p5
            self.pipelineSpringsAddFloat = p6
            return true
        } catch {
            dropFeature(.plusLighter)
            throw error
        }
    }

    private func ensureLayerBlurPipeline() throws -> LayerBlurPipeline {
        let forceInvalid = breakers.shouldForceBuildFailureForTesting(.layerBlur)
        if !forceInvalid, let existing = layerBlur {
            return existing
        }
        do {
            if forceInvalid {
                try Self.failRealMetalBuildForTesting(device: device, feature: .layerBlur)
            }
            let built = try LayerBlurPipeline(device: device, pixelFormat: .rgba16Float)
            self.layerBlur = built
            return built
        } catch {
            dropFeature(.layerBlur)
            throw error
        }
    }

    private func extraPipeline(format: MTLPixelFormat, additive: Bool, springs: Bool) -> MTLRenderPipelineState? {
        let key = ExtraPipelineKey(formatRawValue: format.rawValue, additive: additive, springs: springs)
        if let cached = extraPipelines[key] {
            return cached
        }
        let vert = springs ? uberVertSprings : uberVert
        if let built = try? Self.makePipeline(device: device, vert: vert, frag: uberFrag, format: format, additive: additive) {
            extraPipelines[key] = built
            return built
        }
        return nil
    }

    private func pipelineFor(format: MTLPixelFormat, additive: Bool, springs: Bool) -> MTLRenderPipelineState {
        switch (springs, additive, format) {
        case (false, false, .rgba16Float):
            if pipelineFloat == nil { _ = try? ensureIsolationPipelines() }
            return pipelineFloat ?? ((try? Self.makePipeline(device: device, vert: uberVert, frag: uberFrag, format: .rgba16Float, additive: false)) ?? pipelineSRGB)
        case (false, false, .bgra8Unorm): return pipelineGamma
        case (false, false, .bgra8Unorm_srgb): return pipelineSRGB
        case (false, false, _): return extraPipeline(format: format, additive: false, springs: false) ?? pipelineSRGB
        case (false, true, .rgba16Float): return pipelineAddFloat ?? pipelineFloat ?? pipelineSRGB
        case (false, true, .bgra8Unorm): return pipelineAddGamma ?? pipelineGamma
        case (false, true, .bgra8Unorm_srgb): return pipelineAddSRGB ?? pipelineSRGB
        case (false, true, _):
            return extraPipeline(format: format, additive: true, springs: false)
                ?? extraPipeline(format: format, additive: false, springs: false)
                ?? pipelineAddSRGB ?? pipelineSRGB
        case (true, false, .rgba16Float):
            return pipelineSpringsFloat ?? ((try? Self.makePipeline(device: device, vert: uberVertSprings, frag: uberFrag, format: .rgba16Float, additive: false)) ?? pipelineSpringsSRGB)
        case (true, false, .bgra8Unorm): return pipelineSpringsGamma
        case (true, false, .bgra8Unorm_srgb): return pipelineSpringsSRGB
        case (true, false, _): return extraPipeline(format: format, additive: false, springs: true) ?? pipelineSpringsSRGB
        case (true, true, .rgba16Float): return pipelineSpringsAddFloat ?? pipelineSpringsFloat ?? pipelineSpringsSRGB
        case (true, true, .bgra8Unorm): return pipelineSpringsAddGamma ?? pipelineSpringsGamma
        case (true, true, .bgra8Unorm_srgb): return pipelineSpringsAddSRGB ?? pipelineSpringsSRGB
        case (true, true, _):
            return extraPipeline(format: format, additive: true, springs: true)
                ?? extraPipeline(format: format, additive: false, springs: true)
                ?? pipelineSpringsAddSRGB ?? pipelineSpringsSRGB
        }
    }

    private struct TargetScope {
        let texture: MTLTexture
        let format: MTLPixelFormat
        let origin: SIMD2<Float>
        let contentSize: SIMD2<Float>
        let clearColor: MTLClearColor
        var cleared: Bool
        let scopeInstance: RenderInstance?
        let blurSigma: Float
        let additive: Bool
        let isLayer: Bool
        let cacheNodeId: UInt64?
        let cacheSignature: UInt64?
        let scopeIndex: Int?

        var projection: SIMD4<Float> {
            isLayer ? SIMD4(origin.x, origin.y, Float(texture.width), Float(texture.height)) : .zero
        }
    }

    @discardableResult
    func ensureBackdrop(format: MTLPixelFormat, size: (Int, Int)) -> MTLTexture? {
        let w = min(max(size.0, 1), LayerPoolLimits.maxDimension)
        let h = min(max(size.1, 1), LayerPoolLimits.maxDimension)
        if let existing = backdrops.first(where: { $0.format == format && $0.texture.width == w && $0.texture.height == h }) {
            return existing.texture
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = "rune.effect.backdrop"
        let entry = BackdropEntry(format: format, texture: tex)
        if let idx = backdrops.firstIndex(where: { $0.format == format }) {
            backdrops[idx] = entry
        } else {
            backdrops.append(entry)
        }
        return tex
    }

    private func prepareLayersForFrame(frame: RenderFrame, viewport: (Int, Int)) {
        let vw = max(1, viewport.0)
        let vh = max(1, viewport.1)
        let hasNonHiddenLayer = frame.instances.contains {
            Float(Int($0.params.y.rounded())) == KIND_LAYER && $0.fill.w > 0
        }
        let allowIsolation = hasNonHiddenLayer
            ? (breakers.checkingGpu(.isolation) { try ensureIsolationPipelines() } ?? false)
            : false
        layersPool.prepareLayers(
            device: device,
            instances: frame.instances,
            viewport: SIMD2<Float>(Float(vw), Float(vh)),
            isolate: allowIsolation,
            tracker: frame.residentTracker
        )
        layersPreparedState = (frame.instances, frame.residentTracker, vw, vh, layersPool.planRevision)
    }

    private func hasPlan(for frame: RenderFrame, viewport: (Int, Int)) -> Bool {
        guard let prepared = layersPreparedState, prepared.tracker === frame.residentTracker,
              prepared.width == viewport.0, prepared.height == viewport.1, prepared.revision == layersPool.planRevision,
              prepared.instances.count == frame.instances.count else { return false }
        return prepared.instances.withUnsafeBufferPointer { prior in
            frame.instances.withUnsafeBufferPointer { $0.baseAddress == prior.baseAddress }
        }
    }

    func selectCache(for frame: RenderFrame, viewport: (Int, Int)? = nil, command: MTLCommandBuffer? = nil) -> (any Error)? {
        do {
            try MetalTextureLimits.validate(frame, viewport: viewport, on: device)
        } catch { return error }
        let ordered = layersPool.canUseTextures(in: command)
        if !ordered, let first = frame.elidedLayers.first { return MetalRenderer.RendererError.missingCachedLayer(first.node) }
        // A prepared plan can retire a cache belonging to a clipped-out layer. Its visible
        // layers have already been validated and remain usable while the plan is current.
        if !frame.elidedLayers.isEmpty, !hasPlan(for: frame, viewport: viewport ?? (frame.width, frame.height)),
           let missing = layersPool.missingLayer(in: frame) { return MetalRenderer.RendererError.missingCachedLayer(missing) }
        layersPool.registerTracker(frame.residentTracker)
        uploader.selectRuntime(frame.residentTracker)
        if !ordered {
            layersPool.discardUnorderedSubmission()
            backdropBlur.giveBack()
            backdrops.removeAll()
        }
        return nil
    }

    func prepare(frame: RenderFrame, viewport: (Int, Int)) -> Result<Void, Error> {
        if let error = selectCache(for: frame, viewport: viewport) { return .failure(error) }
        let vw = max(1, viewport.0)
        let vh = max(1, viewport.1)
        lastViewportSize = (vw, vh)
        if !hasExplicitFormat {
            currentFormat = frame.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        }
        guard uploader.syncGlyphAtlas(device: device, atlas: frame.glyphs, generation: frame.glyphGeneration) != nil else {
            return .failure(MetalRenderer.RendererError.textureAllocationFailed(
                resource: "Glyph atlas", width: frame.glyphs.width, height: frame.glyphs.height
            ))
        }
        let preparedPages: [MTLTexture]
        do {
            preparedPages = try uploader.requiredImagePages(
                device: device, pages: frame.imagePages, fallback: frame.images, revision: frame.imageRevision, patch: frame.imagePatch
            )
        } catch {
            return .failure(error)
        }
        _ = uploader.ensureInstanceBuffer(device: device, instances: frame.instances)
        uploader.prepareBatches(instances: frame.instances, glyphPageCount: 1, imagePageCount: max(1, preparedPages.count))

        prepareLayersForFrame(frame: frame, viewport: (vw, vh))

        var needsBackdrop = false
        var hasLayers = false
        for inst in frame.instances {
            let kind = Float(Int(inst.params.y.rounded()))
            if kind == KIND_LAYER {
                hasLayers = true
            } else if (kind == KIND_EFFECT && inst.params.x != 0) || kind == KIND_BACKDROP_BLUR {
                needsBackdrop = true
            }
            if needsBackdrop && hasLayers { break }
        }
        if needsBackdrop {
            ensureBackdrop(format: currentFormat, size: (vw, vh))
            for fmt in extraFormats {
                ensureBackdrop(format: fmt, size: (vw, vh))
            }
            if hasLayers {
                ensureBackdrop(format: .rgba16Float, size: (vw, vh))
            }
        }
        return .success(())
    }

    func setFormat(_ format: MTLPixelFormat) {
        hasExplicitFormat = true
        if currentFormat == format { return }
        if !extraFormats.contains(currentFormat) {
            extraFormats.append(currentFormat)
        }
        extraFormats.removeAll { $0 == format }
        currentFormat = format
        if !backdrops.isEmpty && lastViewportSize.0 > 0 && lastViewportSize.1 > 0 {
            ensureBackdrop(format: format, size: lastViewportSize)
        }
    }

    func draw(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        surfaceRenderer: SurfaceRenderer?,
        hook: EffectHook?,
        backdropHook: EffectBackdropHook?,
        range: Range<Int>? = nil,
        defaultUI: Bool = false
    ) -> Result<Void, Error> {
        let targetW = max(1, target.width)
        let targetH = max(1, target.height)
        if let error = selectCache(for: frame, viewport: (targetW, targetH), command: commandBuffer) { return .failure(error) }
        lastViewportSize = (targetW, targetH)
        let viewport = SIMD2<Float>(Float(targetW), Float(targetH))
        if !hasPlan(for: frame, viewport: (targetW, targetH)) {
            prepareLayersForFrame(frame: frame, viewport: (targetW, targetH))
        }
        layersPool.recordUse(of: commandBuffer)
        defer {
            layersPool.endFrame()
            if range == nil || (range?.upperBound ?? 0) >= frame.instances.count {
                layersPreparedState = nil
            }
        }

        guard let glyphTex = uploader.syncGlyphAtlas(device: device, atlas: frame.glyphs, generation: frame.glyphGeneration) else {
            return .failure(MetalRenderer.RendererError.textureAllocationFailed(
                resource: "Glyph atlas", width: frame.glyphs.width, height: frame.glyphs.height
            ))
        }
        let imagePages: [MTLTexture]
        do {
            imagePages = try uploader.requiredImagePages(
                device: device, pages: frame.imagePages, fallback: frame.images, revision: frame.imageRevision, patch: frame.imagePatch
            )
        } catch {
            return .failure(error)
        }
        uploader.atlasesRead(by: commandBuffer)
        let imageTex = imagePages.first ?? uploader.imageTexture
        let instances = frame.instances
        guard let instanceBuffer = uploader.ensureInstanceBuffer(device: device, instances: instances, readBy: commandBuffer) else {
            return .failure(MetalRenderer.RendererError.metalUnavailable)
        }
        uploader.prepareBatches(instances: instances, glyphPageCount: 1, imagePageCount: max(1, imagePages.count))

        if let r = range {
            let clamped = r.clamped(to: 0..<instances.count)
            if clamped.isEmpty && r.upperBound != instances.count {
                return .success(())
            }
        }
        let sliceRange = range?.clamped(to: 0..<instances.count) ?? (0..<instances.count)

        let springsActive: Bool
        if let bindings = springBindings, !bindings.nodes.isEmpty, bindings.ids.count >= instances.count {
            springsActive = true
        } else {
            springsActive = false
        }

        let byteSource = defaultUI && frame.srgbBlend &&
            (target.pixelFormat == .bgra8Unorm || target.pixelFormat == .rgba8Unorm)
        let globals = RenderGlobals(
            viewport: viewport,
            pad: springsActive ? splitSpringTime(springTimeSeconds) : .zero,
            flags: SIMD4<Float>(frame.srgbBlend ? 1 : 0, byteSource ? 1 : 0, 0, 0)
        )
        if let sr = surfaceRenderer {
            sr.srgbBlend = frame.srgbBlend
            if !frame.surfaces.isEmpty {
                let result = sr.prepare(draws: frame.surfaces, viewport: (UInt32(targetW), UInt32(targetH)))
                if case .failure(let error) = result { return .failure(error) }
            }
        }

        let clear = MTLClearColor(
            red: Double(frame.clearColor.x),
            green: Double(frame.clearColor.y),
            blue: Double(frame.clearColor.z),
            alpha: Double(frame.clearColor.w)
        )
        var stack: [TargetScope] = [
            TargetScope(
                texture: target,
                format: target.pixelFormat,
                origin: .zero,
                contentSize: SIMD2<Float>(Float(targetW), Float(targetH)),
                clearColor: clear,
                cleared: sliceRange.lowerBound > 0,
                scopeInstance: nil,
                blurSigma: 0,
                additive: false,
                isLayer: false,
                cacheNodeId: nil,
                cacheSignature: nil,
                scopeIndex: nil
            )
        ]

        var batchStart = sliceRange.lowerBound
        var backdropBlurCount = 0
        var effectCounter: UInt32 = 0
        var surfaceCursor = 0
        while surfaceCursor < frame.surfaces.count && Int(frame.surfaces[surfaceCursor].beforeInstance) < sliceRange.lowerBound {
            surfaceCursor += 1
        }
        enum LayerScopeKind {
            case isolated
            case inline(pushedScissor: Bool)
        }
        var layerScopeStack: [LayerScopeKind] = []
        var scissorStack: [MTLScissorRect?] = [nil]

        func encodeBatch(start: Int, end: Int, scope: inout TargetScope) {
            let count = end - start
            guard count > 0 else {
                if !scope.cleared {
                    let rpd = MTLRenderPassDescriptor()
                    rpd.colorAttachments[0].texture = scope.texture
                    rpd.colorAttachments[0].loadAction = .clear
                    rpd.colorAttachments[0].clearColor = scope.clearColor
                    rpd.colorAttachments[0].storeAction = .store
                    let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)
                    enc?.endEncoding()
                    scope.cleared = true
                }
                return
            }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = scope.texture
            rpd.colorAttachments[0].loadAction = scope.cleared ? .load : .clear
            rpd.colorAttachments[0].clearColor = scope.clearColor
            rpd.colorAttachments[0].storeAction = .store
            scope.cleared = true

            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
            if let sc = scissorStack.last ?? nil {
                enc.setScissorRect(sc)
            }
            let pipe = pipelineFor(format: scope.format, additive: scope.additive, springs: springsActive)
            enc.setRenderPipelineState(pipe)

            var g = globals
            g.projection = scope.projection
            enc.setVertexBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
            enc.setFragmentBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
            enc.setFragmentTexture(glyphTex, index: 0)
            if imagePages.count > 1 && !uploader.imageBatches.isEmpty {
                for (batchRange, bind) in uploader.imageBatches {
                    let lo = max(start, batchRange.lowerBound)
                    let hi = min(end, batchRange.upperBound)
                    if lo >= hi { continue }
                    let boundTex: MTLTexture?
                    switch bind {
                    case .image(let p):
                        boundTex = p < imagePages.count ? imagePages[p] : imageTex
                    case .glyph:
                        boundTex = imageTex
                    }
                    if let bt = boundTex { enc.setFragmentTexture(bt, index: 1) }
                    enc.setVertexBuffer(instanceBuffer, offset: lo * MemoryLayout<RenderInstance>.stride, index: 0)
                    if springsActive, let bindings = springBindings {
                        enc.setVertexBuffer(bindings.nodesBuffer, offset: 0, index: 2)
                        enc.setVertexBuffer(bindings.idsBuffer, offset: lo * MemoryLayout<UInt32>.stride, index: 3)
                    }
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: hi - lo)
                }
            } else {
                let instanceOffset = start * MemoryLayout<RenderInstance>.stride
                enc.setVertexBuffer(instanceBuffer, offset: instanceOffset, index: 0)
                if springsActive, let bindings = springBindings {
                    enc.setVertexBuffer(bindings.nodesBuffer, offset: 0, index: 2)
                    enc.setVertexBuffer(bindings.idsBuffer, offset: start * MemoryLayout<UInt32>.stride, index: 3)
                }
                if let it = imageTex { enc.setFragmentTexture(it, index: 1) }

                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            }
            enc.endEncoding()
        }

        func flushPendingUpTo(_ idx: Int) {
            if idx > batchStart {
                encodeBatch(start: batchStart, end: idx, scope: &stack[stack.count - 1])
            } else if !stack[stack.count - 1].cleared {
                encodeBatch(start: idx, end: idx, scope: &stack[stack.count - 1])
            }
        }

        func flushSurfacesBefore(_ instanceIndex: Int) {
            let safeIndex = min(instanceIndex, sliceRange.upperBound)
            while surfaceCursor < frame.surfaces.count && Int(frame.surfaces[surfaceCursor].beforeInstance) <= instanceIndex {
                flushPendingUpTo(safeIndex)
                batchStart = safeIndex
                let top = stack[stack.count - 1]
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = top.texture
                rpd.colorAttachments[0].loadAction = top.cleared ? .load : .clear
                rpd.colorAttachments[0].clearColor = top.clearColor
                rpd.colorAttachments[0].storeAction = .store
                stack[stack.count - 1].cleared = true
                if let sr = surfaceRenderer, let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                    if let sc = scissorStack.last ?? nil {
                        enc.setScissorRect(sc)
                    }
                    sr.draw(
                        encoder: enc,
                        index: surfaceCursor,
                        pixelFormat: top.format,
                        blend: top.additive ? .plusLighter : .sourceOver,
                        targetViewport: SIMD4<Float>(
                            Float(top.texture.width),
                            Float(top.texture.height),
                            top.origin.x,
                            top.origin.y
                        )
                    )
                    enc.endEncoding()
                }
                surfaceCursor += 1
            }
        }

        func compositeLayer(
            source: MTLTexture,
            destRect: SIMD4<Float>,
            contentSize: SIMD2<Float>,
            scopeInst: RenderInstance,
            clampSource: Bool,
            radiiOverride: SIMD4<Float>? = nil,
            clearIndex: Int
        ) {
            if !stack[stack.count - 1].cleared {
                encodeBatch(start: clearIndex, end: clearIndex, scope: &stack[stack.count - 1])
            }
            let parent = stack[stack.count - 1]
            let sizeMismatch = abs(contentSize.x - destRect.z) > 0.5 || abs(contentSize.y - destRect.w) > 0.5
            let uvRect = sizeMismatch ? SIMD4<Float>(0, 0, contentSize.x, contentSize.y) : .zero
            var compositeInst = RenderInstance(
                rect: destRect,
                radii: radiiOverride ?? scopeInst.radii,
                fill: SIMD4<Float>(1, 1, 1, scopeInst.fill.w),
                border: scopeInst.border,
                params: SIMD4<Float>(clampSource ? 1.0 : 0.0, Float(KIND_LAYER), 0, 0),
                uv: uvRect,
                clip: scopeInst.clip,
                fade: scopeInst.fade
            )
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = parent.texture
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                if let sc = scissorStack.last ?? nil {
                    enc.setScissorRect(sc)
                }
                let compPipe = pipelineFor(format: parent.format, additive: parent.additive, springs: false)
                enc.setRenderPipelineState(compPipe)
                var g = globals
                g.projection = parent.projection
                enc.setVertexBytes(&compositeInst, length: MemoryLayout<RenderInstance>.stride, index: 0)
                enc.setVertexBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
                enc.setFragmentBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
                enc.setFragmentTexture(glyphTex, index: 0)
                enc.setFragmentTexture(source, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
        }

        func findMatchingLayerEnd(from beginIndex: Int) -> Int {
            var depth = 1
            var matchEnd = beginIndex + 1
            while matchEnd < instances.count {
                let k = Float(Int(instances[matchEnd].params.y.rounded()))
                if k == KIND_LAYER {
                    depth += 1
                } else if k == KIND_LAYER_END {
                    depth -= 1
                    if depth == 0 { break }
                }
                matchEnd += 1
            }
            return matchEnd
        }

        var i = sliceRange.lowerBound
        while i < sliceRange.upperBound {
            flushSurfacesBefore(i)

            let inst = instances[i]
            let kind = Float(Int(inst.params.y.rounded()))

            if kind == KIND_LAYER {
                flushPendingUpTo(i)
                batchStart = i + 1

                let scopeIdx = layersPool.scopeIndex(forBeginInstance: i)
                let disp: LayerDisposition? = scopeIdx.flatMap {
                    $0 < layersPool.planner.dispositions.count ? layersPool.planner.dispositions[$0] : nil
                }

                switch disp {
                case .none, .some(.skip):
                    let matchEnd = findMatchingLayerEnd(from: i)
                    while surfaceCursor < frame.surfaces.count && Int(frame.surfaces[surfaceCursor].beforeInstance) <= matchEnd {
                        surfaceCursor += 1
                    }
                    batchStart = min(instances.count, matchEnd + 1)
                    i = matchEnd + 1
                    continue

                case .some(.inline):
                    if inst.clip != NO_CLIP {
                        let top = stack[stack.count - 1]
                        let tw = top.texture.width
                        let th = top.texture.height
                        var x0 = min(max(Int(floorf(inst.clip.x) - top.origin.x), 0), tw)
                        var y0 = min(max(Int(floorf(inst.clip.y) - top.origin.y), 0), th)
                        var x1 = min(max(Int(ceilf(inst.clip.z) - top.origin.x), 0), tw)
                        var y1 = min(max(Int(ceilf(inst.clip.w) - top.origin.y), 0), th)
                        if let outer = scissorStack.last ?? nil {
                            x0 = max(x0, outer.x)
                            y0 = max(y0, outer.y)
                            x1 = min(x1, outer.x + outer.width)
                            y1 = min(y1, outer.y + outer.height)
                        }
                        if x1 <= x0 || y1 <= y0 {
                            let matchEnd = findMatchingLayerEnd(from: i)
                            while surfaceCursor < frame.surfaces.count && Int(frame.surfaces[surfaceCursor].beforeInstance) <= matchEnd {
                                surfaceCursor += 1
                            }
                            batchStart = min(instances.count, matchEnd + 1)
                            i = matchEnd + 1
                            continue
                        }
                        scissorStack.append(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                        layerScopeStack.append(.inline(pushedScissor: true))
                    } else {
                        layerScopeStack.append(.inline(pushedScissor: false))
                    }
                    i += 1
                    continue

                case .some(.cached(let rect, let cache)):
                    let additive = inst.params.x >= 0.5
                    let cachedHit: (texture: MTLTexture, contentSize: SIMD2<Float>)?
                    if let sIdx = scopeIdx, let entry = layersPool.targetEntry(at: sIdx) {
                        cachedHit = (entry.slot.texture, entry.contentSize)
                    } else {
                        let cacheNid = unpackFloat4ToU64(inst.radii)
                        let cacheSig = unpackFloat4ToU64(inst.uv)
                        cachedHit = layersPool.claimRetained(key: cacheNid, signature: cacheSig)
                    }
                    if let hit = cachedHit {
                        let matchEnd = findMatchingLayerEnd(from: i)
                        compositeLayer(
                            source: hit.texture,
                            destRect: rect,
                            contentSize: hit.contentSize,
                            scopeInst: inst,
                            clampSource: additive,
                            radiiOverride: .zero,
                            clearIndex: i
                        )
                        while surfaceCursor < frame.surfaces.count && Int(frame.surfaces[surfaceCursor].beforeInstance) <= matchEnd {
                            surfaceCursor += 1
                        }
                        batchStart = min(instances.count, matchEnd + 1)
                        i = matchEnd + 1
                        continue
                    }
                    // Defensive fallback if target vanished mid-frame
                    fallthrough

                case .some(.render(let rect, let cache)):
                    let sigma = min(max(inst.params.z, 0.0), LayerBlurConstants.maxSigma)
                    let targetRect = rect
                    let additive = inst.params.x >= 0.5
                    let scopeAdditive = additive && (breakers.checkingGpu(.plusLighter) {
                        try ensurePlusLighterPipelines()
                    } ?? false)
                    let committedTex = scopeIdx.flatMap { layersPool.targetEntry(at: $0)?.slot.texture }
                    if let layerTex = committedTex {
                        stack.append(
                            TargetScope(
                                texture: layerTex,
                                format: .rgba16Float,
                                origin: SIMD2<Float>(targetRect.x, targetRect.y),
                                contentSize: SIMD2<Float>(targetRect.z, targetRect.w),
                                clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
                                cleared: false,
                                scopeInstance: inst,
                                blurSigma: sigma,
                                additive: scopeAdditive,
                                isLayer: true,
                                cacheNodeId: cache?.0,
                                cacheSignature: cache?.1,
                                scopeIndex: scopeIdx
                            )
                        )
                        scissorStack.append(nil)
                        layerScopeStack.append(.isolated)
                    } else {
                        layerScopeStack.append(.inline(pushedScissor: false))
                    }
                    i += 1
                    continue
                }
            }

            if kind == KIND_LAYER_END {
                flushPendingUpTo(i)
                batchStart = i + 1
                guard let scopeKind = layerScopeStack.popLast() else {
                    i += 1
                    continue
                }
                switch scopeKind {
                case .inline(let pushedScissor):
                    if pushedScissor {
                        _ = scissorStack.popLast()
                    }
                    i += 1
                    continue
                case .isolated:
                    _ = scissorStack.popLast()
                    guard stack.count > 1 else {
                        i += 1
                        continue
                    }
                    let finished = stack.removeLast()
                    guard let scopeInst = finished.scopeInstance else {
                        i += 1
                        continue
                    }

                    layersPool.recordExtraPass(1)
                    var compositedSource = finished.texture
                    if finished.blurSigma > 0.05,
                       let blurPipeline = breakers.checkingGpu(.layerBlur, { try ensureLayerBlurPipeline() }) {
                        if let blurred = blurPipeline.encode(
                            device: device,
                            commandBuffer: commandBuffer,
                            pool: layersPool,
                            source: finished.texture,
                            sigma: finished.blurSigma,
                            additive: finished.additive
                        ) {
                            compositedSource = blurred
                        }
                    }

                    if let nid = finished.cacheNodeId, let sig = finished.cacheSignature, let sIdx = finished.scopeIndex {
                        if compositedSource !== finished.texture {
                            layersPool.detachInUse(compositedSource)
                            layersPool.updateTargetTexture(at: sIdx, texture: compositedSource)
                            layersPool.recycleTarget(finished.texture)
                        }
                        layersPool.finishCachedLayer(at: sIdx, node: nid, signature: sig)
                    }

                    let destRect = SIMD4<Float>(
                        finished.origin.x,
                        finished.origin.y,
                        finished.contentSize.x,
                        finished.contentSize.y
                    )
                    compositeLayer(
                        source: compositedSource,
                        destRect: destRect,
                        contentSize: finished.contentSize,
                        scopeInst: scopeInst,
                        clampSource: scopeInst.params.x >= 0.5,
                        radiiOverride: (finished.cacheNodeId != nil || scopeInst.params.w >= 0.5) ? .zero : scopeInst.radii,
                        clearIndex: i
                    )
                    if finished.cacheNodeId == nil, compositedSource !== finished.texture {
                        layersPool.recycleTarget(compositedSource)
                    }
                    i += 1
                    continue
                }
            }

            if kind == KIND_EFFECT {
                flushPendingUpTo(i)
                batchStart = i + 1

                let cur = stack[stack.count - 1]
                let edge: (Float, Float, Int) -> Int = { v, o, maxV in
                    min(max(Int(v - o), 0), maxV)
                }
                let bleed = max(Float(0), inst.params.z)
                let sx0 = max(floorf(inst.clip.x), floorf(inst.rect.x - bleed))
                let sy0 = max(floorf(inst.clip.y), floorf(inst.rect.y - bleed))
                let sx1 = min(ceilf(inst.clip.z), ceilf(inst.rect.x + inst.rect.z + bleed))
                let sy1 = min(ceilf(inst.clip.w), ceilf(inst.rect.y + inst.rect.w + bleed))
                let x0 = edge(sx0, cur.origin.x, cur.texture.width)
                let y0 = edge(sy0, cur.origin.y, cur.texture.height)
                let x1 = edge(sx1, cur.origin.x, cur.texture.width)
                let y1 = edge(sy1, cur.origin.y, cur.texture.height)
                if x1 <= x0 || y1 <= y0 {
                    i += 1
                    continue
                }

                let mark = i < frame.marks.count ? frame.marks[i] : effectMark(inst)
                let wantsBackdrop = inst.params.x >= 0.5 && (hook != nil || backdropHook != nil)
                let canCopyBackdrop = cur.isLayer
                    || (cur.texture.storageMode != .memoryless && cur.texture.usage.contains(.shaderRead))

                var backdropSnap: MTLTexture?
                if wantsBackdrop && canCopyBackdrop {
                    let vw = max(1, Int(globals.viewport.x))
                    let vh = max(1, Int(globals.viewport.y))
                    if let snap = ensureBackdrop(format: cur.format, size: (vw, vh)) {
                        if cur.isLayer {
                            let clearPass = MTLRenderPassDescriptor()
                            clearPass.colorAttachments[0].texture = snap
                            clearPass.colorAttachments[0].loadAction = .clear
                            clearPass.colorAttachments[0].storeAction = .store
                            clearPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                            if let clearEnc = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) {
                                clearEnc.endEncoding()
                            }
                        }
                        let srcX = max(0, Int(-cur.origin.x))
                        let srcY = max(0, Int(-cur.origin.y))
                        let dstX = max(0, Int(cur.origin.x))
                        let dstY = max(0, Int(cur.origin.y))
                        let copyW = min(cur.texture.width - srcX, vw - dstX)
                        let copyH = min(cur.texture.height - srcY, vh - dstY)
                        if copyW > 0 && copyH > 0, let blit = commandBuffer.makeBlitCommandEncoder() {
                            blit.copy(
                                from: cur.texture,
                                sourceSlice: 0,
                                sourceLevel: 0,
                                sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                                sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                                to: snap,
                                destinationSlice: 0,
                                destinationLevel: 0,
                                destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                            )
                            blit.endEncoding()
                        }
                        backdropSnap = snap
                    }
                }

                var layerOpacity: Float = 1.0
                var layerTurn: Float = 0.0
                if cur.isLayer {
                    for scope in stack where scope.isLayer {
                        if let si = scope.scopeInstance {
                            layerOpacity *= si.fill.w
                            if si.border.y != 0 {
                                layerTurn = si.border.y
                            }
                        }
                    }
                }
                let site = EffectSite(
                    index: effectCounter,
                    instance: inst,
                    mark: mark,
                    data: inst.uv,
                    scale: inst.params.w,
                    pixelFormat: cur.format,
                    origin: cur.origin,
                    pixelSize: (cur.texture.width, cur.texture.height),
                    inLayer: cur.isLayer,
                    opacity: layerOpacity,
                    turn: layerTurn,
                    srgbBlend: frame.srgbBlend,
                    backdrop: backdropSnap
                )

                if let bh = backdropHook, wantsBackdrop {
                    bh(.backdrop(commandBuffer), site)
                }

                if hook != nil || backdropHook != nil {
                    let rpd = MTLRenderPassDescriptor()
                    rpd.colorAttachments[0].texture = cur.texture
                    rpd.colorAttachments[0].loadAction = .load
                    rpd.colorAttachments[0].storeAction = .store
                    if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                        enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                        hook?(enc, site)
                        backdropHook?(.draw(enc), site)
                        enc.endEncoding()
                    }
                }
                effectCounter &+= 1
                i += 1
                continue
            }

            if kind == KIND_BACKDROP_BLUR {
                flushPendingUpTo(i)
                batchStart = i + 1
                if backdropBlurCount < MAX_BACKDROP_BLURS {
                    backdropBlurCount += 1
                    let cur = stack[stack.count - 1]
                    var layerGlobals = globals
                    layerGlobals.projection = cur.projection
                    backdropBlur.encode(
                        device: device,
                        commandBuffer: commandBuffer,
                        source: cur.texture,
                        target: cur.texture,
                        targetFormat: cur.format,
                        instanceIndex: i,
                        instance: inst,
                        instanceBuffer: instanceBuffer,
                        viewport: SIMD2<Float>(Float(cur.texture.width), Float(cur.texture.height)),
                        originOffset: cur.origin
                    ) { encoder in
                        encoder.setVertexBytes(&layerGlobals, length: MemoryLayout<RenderGlobals>.stride, index: 1)
                    }
                }
                i += 1
                continue
            }
            i += 1
        }

        // Flush remaining batch & trailing surfaces on the root target
        flushPendingUpTo(sliceRange.upperBound)
        flushSurfacesBefore(sliceRange.upperBound)
        if !frame.surfaces.isEmpty {
            surfaceRenderer?.trackSubmission(commandBuffer: commandBuffer)
        }
        return .success(())
    }

    func renderOffscreen(
        _ frame: RenderFrame,
        commandQueue: MTLCommandQueue,
        encode: (MTLTexture, MTLCommandBuffer) throws -> Void
    ) throws -> Frame {
        if let error = selectCache(for: frame) { throw error }
        let w = max(1, frame.width)
        let h = max(1, frame.height)
        let pixelFormat: MTLPixelFormat = frame.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: w,
            height: h,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let targetTex = device.makeTexture(descriptor: texDesc) else {
            throw MetalRenderer.RendererError.textureAllocationFailed(resource: "Render target", width: w, height: h)
        }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else {
            throw MetalRenderer.RendererError.metalUnavailable
        }

        try encode(targetTex, cmdBuf)
        gpuLoss.attach(to: cmdBuf)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        if let error = cmdBuf.error { throw error }

        var bgra = Array<UInt8>(repeating: 0, count: w * h * 4)
        targetTex.getBytes(&bgra, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var rgba = Array<UInt8>(repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let b = bgra[i]
            let g = bgra[i + 1]
            let r = bgra[i + 2]
            let a = bgra[i + 3]
            if a > 0 && a < 255 {
                let af = Float(a) / 255.0
                if frame.srgbBlend {
                    rgba[i] = UInt8(min(255.0, (Float(r) / af).rounded()))
                    rgba[i + 1] = UInt8(min(255.0, (Float(g) / af).rounded()))
                    rgba[i + 2] = UInt8(min(255.0, (Float(b) / af).rounded()))
                } else {
                    let lr = min(1.0, RefShader.srgbToLinear(Float(r) / 255.0) / af)
                    let lg = min(1.0, RefShader.srgbToLinear(Float(g) / 255.0) / af)
                    let lb = min(1.0, RefShader.srgbToLinear(Float(b) / 255.0) / af)
                    rgba[i] = UInt8((RefShader.linearToSRGB(lr) * 255.0).rounded())
                    rgba[i + 1] = UInt8((RefShader.linearToSRGB(lg) * 255.0).rounded())
                    rgba[i + 2] = UInt8((RefShader.linearToSRGB(lb) * 255.0).rounded())
                }
                rgba[i + 3] = a
            } else {
                rgba[i] = r
                rgba[i + 1] = g
                rgba[i + 2] = b
                rgba[i + 3] = a
            }
        }
        return Frame(width: w, height: h, rgba: rgba)
    }
}

extension MetalRenderer {
    /// Builds a frame using the cached layer textures available on this renderer.
    public func frame<State>(_ runtime: Runtime<State>, at time: Double) -> RenderFrame {
        renderEngine.layersPool.registerTracker(runtime.residentCacheTracker)
        return runtime.renderFrame(at: time)
    }

    /// Renders an upstream-parity `RenderFrame` into a `CAMetalDrawable` and presents it.
    @discardableResult
    public func draw(
        frame: RenderFrame,
        to drawable: CAMetalDrawable,
        hook: EffectHook? = nil,
        backdropHook: EffectBackdropHook? = nil,
        synchronized: Bool = false
    ) -> Result<Void, Error> {
        let viewport = (drawable.texture.width, drawable.texture.height)
        if let error = renderEngine.selectCache(for: frame, viewport: viewport) { return .failure(error) }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return .failure(RendererError.metalUnavailable) }
        let encoded = encodeUI(frame: frame, into: drawable.texture, commandBuffer: cmdBuf, hook: hook, backdropHook: backdropHook)
        if case .failure = encoded { return encoded }
        renderEngine.gpuLoss.attach(to: cmdBuf)
        if synchronized {
            cmdBuf.commit()
            cmdBuf.waitUntilScheduled()
            drawable.present()
        } else {
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
        GpuEvents.presented()
        return .success(())
    }

    /// Draws the default UI into its known root target, including a compositor's drawUI callback.
    @discardableResult
    internal func encodeUI(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        hook: EffectHook? = nil,
        backdropHook: EffectBackdropHook? = nil
    ) -> Result<Void, Error> {
        renderEngine.draw(
            frame: frame, into: target, commandBuffer: commandBuffer,
            surfaceRenderer: acquireSurfaceRenderer(pixelFormat: target.pixelFormat),
            hook: hook, backdropHook: backdropHook, defaultUI: true
        )
    }

    /// Encodes a `RenderFrame` into `target` without committing (matches `render::Renderer::draw_range`).
    @discardableResult
    public func drawRange(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        range: Range<Int>? = nil
    ) -> Result<Void, Error> {
        let sr = acquireSurfaceRenderer(pixelFormat: target.pixelFormat)
        return renderEngine.draw(
            frame: frame,
            into: target,
            commandBuffer: commandBuffer,
            surfaceRenderer: sr,
            hook: nil,
            backdropHook: nil,
            range: range
        )
    }

    /// Encodes a `RenderFrame` with an `EffectHook` callback (`render::Renderer::draw_range_with`).
    @discardableResult
    public func drawRangeWith(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        range: Range<Int>? = nil,
        hook: EffectHook?
    ) -> Result<Void, Error> {
        let sr = acquireSurfaceRenderer(pixelFormat: target.pixelFormat)
        return renderEngine.draw(
            frame: frame,
            into: target,
            commandBuffer: commandBuffer,
            surfaceRenderer: sr,
            hook: hook,
            backdropHook: nil,
            range: range
        )
    }

    /// Encodes a `RenderFrame` with a two-phase `EffectBackdropHook` (`render::Renderer::draw_with_backdrop`).
    @discardableResult
    public func drawWithBackdrop(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        hook: EffectBackdropHook?
    ) -> Result<Void, Error> {
        let sr = acquireSurfaceRenderer(pixelFormat: target.pixelFormat)
        return renderEngine.draw(
            frame: frame,
            into: target,
            commandBuffer: commandBuffer,
            surfaceRenderer: sr,
            hook: nil,
            backdropHook: hook
        )
    }

    /// Headless offscreen `RenderFrame` render + straight-RGBA readback.
    public func renderOffscreen(
        _ frame: RenderFrame,
        hook: EffectHook? = nil,
        backdropHook: EffectBackdropHook? = nil
    ) throws -> Frame {
        try renderEngine.renderOffscreen(frame, commandQueue: commandQueue) { target, commands in
            try encodeUI(frame: frame, into: target, commandBuffer: commands, hook: hook, backdropHook: backdropHook).get()
        }
    }

    // MARK: - GPU Springs, Cache Budget & `#819` Give-Back

    public func withSprings(nodes: [GPUSpringNode], ids: [UInt32], timeSeconds: Double = 0) {
        if let existing = renderEngine.springBindings {
            existing.update(device: device, nodes: nodes, ids: ids)
        } else {
            renderEngine.springBindings = GPUSpringBindings(device: device, nodes: nodes, ids: ids)
        }
        renderEngine.springTimeSeconds = timeSeconds
    }

    public func setSpringTime(_ timeSeconds: Double) {
        renderEngine.springTimeSeconds = timeSeconds
    }

    public func updateSpringNode(index: Int, node: GPUSpringNode) {
        renderEngine.springBindings?.updateNode(index: index, node: node)
    }

    public func clearSprings() {
        renderEngine.springBindings = nil
    }

    public func springsAnimating(at timeSeconds: Double) -> Bool {
        renderEngine.springBindings?.hasActiveMotion(at: timeSeconds) ?? false
    }

    public var backdropTextures: [MTLTexture] {
        renderEngine.backdrops.map(\.texture)
    }

    @discardableResult
    public func prepare(frame: RenderFrame, viewport: (Int, Int)) -> Result<Void, Error> {
        renderEngine.prepare(frame: frame, viewport: viewport)
    }

    public func setFormat(_ format: MTLPixelFormat) {
        renderEngine.setFormat(format)
    }

    /// `#819` GPU memory give-back on window rest / occlusion.
    public func giveBack(all: Bool = false, residentCaches: Bool = false) {
        renderEngine.layersPool.giveBack(all: all, residentCaches: residentCaches)
        renderEngine.layersPreparedState = nil
        renderEngine.backdropBlur.giveBack()
        renderEngine.backdrops.removeAll()
        renderEngine.extraFormats.removeAll()
        if all {
            renderEngine.uploader.trimUploads()
        }
    }

    public func trimUploads() {
        renderEngine.uploader.trimUploads()
    }

    public func layerStats() -> LayerStats {
        renderEngine.layersPool.stats()
    }

    public func setLayerCacheBudget(_ bytes: Int) {
        renderEngine.layersPool.setCacheBudget(bytes)
    }

    public var pipelineBreakers: PipelineBreakers {
        renderEngine.breakers
    }

    public var gpuTracker: GpuDeviceTracker {
        renderEngine.gpuLoss
    }

    public var layersPool: LayersPool {
        renderEngine.layersPool
    }

    public var uploader: AtlasUploader {
        renderEngine.uploader
    }
}
#endif
