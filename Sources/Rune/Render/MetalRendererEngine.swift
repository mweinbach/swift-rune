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
    let pipelineSRGB: MTLRenderPipelineState
    let pipelineGamma: MTLRenderPipelineState
    let pipelineFloat: MTLRenderPipelineState
    let pipelineAddSRGB: MTLRenderPipelineState
    let pipelineAddGamma: MTLRenderPipelineState
    let pipelineAddFloat: MTLRenderPipelineState

    let pipelineSpringsSRGB: MTLRenderPipelineState
    let pipelineSpringsGamma: MTLRenderPipelineState
    let pipelineSpringsFloat: MTLRenderPipelineState
    let pipelineSpringsAddSRGB: MTLRenderPipelineState
    let pipelineSpringsAddGamma: MTLRenderPipelineState
    let pipelineSpringsAddFloat: MTLRenderPipelineState

    let layerBlur: LayerBlurPipeline
    let backdropBlur: BackdropBlurPass
    let layersPool: LayersPool = LayersPool()
    let uploader: AtlasUploader = AtlasUploader()

    var springBindings: GPUSpringBindings?
    var springTimeSeconds: Double = 0

    init(device: MTLDevice) throws {
        self.device = device
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: RenderShaders.shaderMSL, options: nil)
        } catch {
            throw MetalRenderer.RendererError.shaderCompileFailed("RenderShaders.shaderMSL: \(error)")
        }

        guard let vs = lib.makeFunction(name: "vs"),
              let vsSprings = lib.makeFunction(name: "vs_springs"),
              let fs = lib.makeFunction(name: "fs") else {
            throw MetalRenderer.RendererError.shaderCompileFailed("Missing vs/vs_springs/fs in RenderShaders.shaderMSL")
        }

        func makePipe(vert: MTLFunction, format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vert
            desc.fragmentFunction = fs
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

        self.pipelineSRGB = try makePipe(vert: vs, format: .bgra8Unorm_srgb, additive: false)
        self.pipelineGamma = try makePipe(vert: vs, format: .bgra8Unorm, additive: false)
        self.pipelineFloat = try makePipe(vert: vs, format: .rgba16Float, additive: false)
        self.pipelineAddSRGB = try makePipe(vert: vs, format: .bgra8Unorm_srgb, additive: true)
        self.pipelineAddGamma = try makePipe(vert: vs, format: .bgra8Unorm, additive: true)
        self.pipelineAddFloat = try makePipe(vert: vs, format: .rgba16Float, additive: true)

        self.pipelineSpringsSRGB = try makePipe(vert: vsSprings, format: .bgra8Unorm_srgb, additive: false)
        self.pipelineSpringsGamma = try makePipe(vert: vsSprings, format: .bgra8Unorm, additive: false)
        self.pipelineSpringsFloat = try makePipe(vert: vsSprings, format: .rgba16Float, additive: false)
        self.pipelineSpringsAddSRGB = try makePipe(vert: vsSprings, format: .bgra8Unorm_srgb, additive: true)
        self.pipelineSpringsAddGamma = try makePipe(vert: vsSprings, format: .bgra8Unorm, additive: true)
        self.pipelineSpringsAddFloat = try makePipe(vert: vsSprings, format: .rgba16Float, additive: true)

        do {
            self.layerBlur = try LayerBlurPipeline(device: device, pixelFormat: .rgba16Float)
            self.backdropBlur = try BackdropBlurPass(device: device)
        } catch {
            throw MetalRenderer.RendererError.shaderCompileFailed("Sub-pass compilation failed: \(error)")
        }
    }

    private func pipelineFor(format: MTLPixelFormat, additive: Bool, springs: Bool) -> MTLRenderPipelineState {
        switch (springs, additive, format) {
        case (false, false, .rgba16Float): return pipelineFloat
        case (false, false, .bgra8Unorm): return pipelineGamma
        case (false, false, _): return pipelineSRGB
        case (false, true, .rgba16Float): return pipelineAddFloat
        case (false, true, .bgra8Unorm): return pipelineAddGamma
        case (false, true, _): return pipelineAddSRGB
        case (true, false, .rgba16Float): return pipelineSpringsFloat
        case (true, false, .bgra8Unorm): return pipelineSpringsGamma
        case (true, false, _): return pipelineSpringsSRGB
        case (true, true, .rgba16Float): return pipelineSpringsAddFloat
        case (true, true, .bgra8Unorm): return pipelineSpringsAddGamma
        case (true, true, _): return pipelineSpringsAddSRGB
        }
    }

    private struct TargetScope {
        let texture: MTLTexture
        let format: MTLPixelFormat
        let origin: SIMD2<Float>
        let clearColor: MTLClearColor
        var cleared: Bool
        let scopeInstance: RenderInstance?
        let blurSigma: Float
        let additive: Bool
        let isLayer: Bool
    }

    func draw(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        surfaceRenderer: SurfaceRenderer?,
        hook: EffectHook?,
        backdropHook: EffectBackdropHook?
    ) {
        layersPool.beginFrame()
        defer { layersPool.endFrame() }

        let targetW = max(1, target.width)
        let targetH = max(1, target.height)
        let viewport = SIMD2<Float>(Float(targetW), Float(targetH))

        let glyphTex = uploader.syncGlyphAtlas(device: device, atlas: frame.glyphs, generation: frame.glyphGeneration)
        let imageTex = uploader.syncImageAtlas(device: device, atlas: frame.images, revision: 1)
        let instances = frame.instances
        guard let instanceBuffer = uploader.ensureInstanceBuffer(device: device, instances: instances) else {
            return
        }

        let springsActive: Bool
        if let bindings = springBindings, !bindings.nodes.isEmpty, bindings.ids.count >= instances.count {
            springsActive = true
        } else {
            springsActive = false
        }

        let globals = RenderGlobals(
            viewport: viewport,
            pad: springsActive ? splitSpringTime(springTimeSeconds) : .zero,
            flags: SIMD4<Float>(frame.srgbBlend ? 1.0 : 0.0, 0, 0, 0),
            projection: SIMD4<Float>(0, 0, Float(targetW), Float(targetH))
        )
        guard let rootGlobalsBuffer = uploader.ensureGlobalsBuffer(device: device, globals: globals) else {
            return
        }

        if let sr = surfaceRenderer {
            sr.srgbBlend = frame.srgbBlend
            if !frame.surfaces.isEmpty {
                sr.prepare(draws: frame.surfaces, viewport: (UInt32(targetW), UInt32(targetH)))
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
                clearColor: clear,
                cleared: false,
                scopeInstance: nil,
                blurSigma: 0,
                additive: false,
                isLayer: false
            )
        ]

        var batchStart = 0
        var backdropBlurCount = 0
        var effectCounter: UInt32 = 0
        var surfaceCursor = 0

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
            let pipe = pipelineFor(format: scope.format, additive: false, springs: springsActive)
            enc.setRenderPipelineState(pipe)

            var g = globals
            g.projection = SIMD4<Float>(scope.origin.x, scope.origin.y, Float(scope.texture.width), Float(scope.texture.height))
            let instanceOffset = start * MemoryLayout<RenderInstance>.stride
            enc.setVertexBuffer(instanceBuffer, offset: instanceOffset, index: 0)
            enc.setVertexBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
            if springsActive, let bindings = springBindings {
                enc.setVertexBuffer(bindings.nodesBuffer, offset: 0, index: 2)
                enc.setVertexBuffer(bindings.idsBuffer, offset: start * MemoryLayout<UInt32>.stride, index: 3)
            }
            enc.setFragmentBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
            if let gt = glyphTex { enc.setFragmentTexture(gt, index: 0) }
            if let it = imageTex { enc.setFragmentTexture(it, index: 1) }

            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
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
            while surfaceCursor < frame.surfaces.count && Int(frame.surfaces[surfaceCursor].beforeInstance) <= instanceIndex {
                flushPendingUpTo(instanceIndex)
                batchStart = instanceIndex
                let top = stack[stack.count - 1]
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = top.texture
                rpd.colorAttachments[0].loadAction = top.cleared ? .load : .clear
                rpd.colorAttachments[0].clearColor = top.clearColor
                rpd.colorAttachments[0].storeAction = .store
                stack[stack.count - 1].cleared = true
                if let sr = surfaceRenderer, let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                    sr.draw(
                        encoder: enc,
                        index: surfaceCursor,
                        pixelFormat: top.format,
                        blend: .sourceOver
                    )
                    enc.endEncoding()
                }
                surfaceCursor += 1
            }
        }

        for i in 0..<instances.count {
            flushSurfacesBefore(i)

            let inst = instances[i]
            let kind = Float(Int(inst.params.y.rounded()))

            if kind == KIND_LAYER {
                flushPendingUpTo(i)
                batchStart = i + 1

                let sigma = min(max(inst.params.z, 0.0), LayerBlurConstants.maxSigma)
                let pad: Float = sigma > 0 ? ceilf(min(sigma * 3.0, 96.0)) : 0
                let ox = floorf(inst.rect.x - pad)
                let oy = floorf(inst.rect.y - pad)
                let lw = max(1, Int(ceilf(inst.rect.x + inst.rect.z + pad) - ox))
                let lh = max(1, Int(ceilf(inst.rect.y + inst.rect.w + pad) - oy))

                if let layerTex = layersPool.acquireTarget(device: device, width: lw, height: lh, format: .rgba16Float) {
                    stack.append(
                        TargetScope(
                            texture: layerTex,
                            format: .rgba16Float,
                            origin: SIMD2<Float>(ox, oy),
                            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
                            cleared: false,
                            scopeInstance: inst,
                            blurSigma: sigma,
                            additive: inst.params.x >= 0.5,
                            isLayer: true
                        )
                    )
                }
                continue
            }

            if kind == KIND_LAYER_END {
                flushPendingUpTo(i)
                batchStart = i + 1
                guard stack.count > 1 else { continue }
                let finished = stack.removeLast()
                guard let scopeInst = finished.scopeInstance else { continue }

                var compositedSource = finished.texture
                if finished.blurSigma > 0.05 {
                    if let blurred = layerBlur.encode(
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

                // Ensure parent is initialized before compositing the layer quad
                if !stack[stack.count - 1].cleared {
                    encodeBatch(start: i, end: i, scope: &stack[stack.count - 1])
                }
                let parent = stack[stack.count - 1]
                var compositeInst = RenderInstance(
                    rect: SIMD4<Float>(
                        finished.origin.x,
                        finished.origin.y,
                        Float(compositedSource.width),
                        Float(compositedSource.height)
                    ),
                    radii: scopeInst.radii,
                    fill: SIMD4<Float>(1, 1, 1, scopeInst.fill.w),
                    border: scopeInst.border,
                    params: SIMD4<Float>(finished.additive ? 1.0 : 0.0, Float(KIND_LAYER), 0, 0),
                    uv: .zero,
                    clip: scopeInst.clip,
                    fade: scopeInst.fade
                )

                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = parent.texture
                rpd.colorAttachments[0].loadAction = .load
                rpd.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                    let compPipe = pipelineFor(format: parent.format, additive: finished.additive, springs: false)
                    enc.setRenderPipelineState(compPipe)
                    var g = globals
                    g.projection = SIMD4<Float>(parent.origin.x, parent.origin.y, Float(parent.texture.width), Float(parent.texture.height))
                    enc.setVertexBytes(&compositeInst, length: MemoryLayout<RenderInstance>.stride, index: 0)
                    enc.setVertexBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
                    enc.setFragmentBytes(&g, length: MemoryLayout<RenderGlobals>.stride, index: 1)
                    if let gt = glyphTex { enc.setFragmentTexture(gt, index: 0) }
                    enc.setFragmentTexture(compositedSource, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }
                continue
            }

            if kind == KIND_EFFECT {
                flushPendingUpTo(i)
                batchStart = i + 1

                let cur = stack[stack.count - 1]
                let mark = i < frame.marks.count ? frame.marks[i] : effectMark(inst)
                let wantsBackdrop = inst.params.z >= 0.5 && backdropHook != nil

                var backdropSnap: MTLTexture?
                if wantsBackdrop {
                    let rx = max(0, Int(floorf(inst.rect.x - cur.origin.x)))
                    let ry = max(0, Int(floorf(inst.rect.y - cur.origin.y)))
                    let rw = min(max(1, Int(ceilf(inst.rect.z))), max(1, cur.texture.width - rx))
                    let rh = min(max(1, Int(ceilf(inst.rect.w))), max(1, cur.texture.height - ry))
                    if let snap = layersPool.acquireTarget(device: device, width: rw, height: rh, format: cur.format, label: "rune.effect.backdrop"),
                       let blit = commandBuffer.makeBlitCommandEncoder()
                    {
                        blit.copy(
                            from: cur.texture,
                            sourceSlice: 0,
                            sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: min(rx, cur.texture.width - 1), y: min(ry, cur.texture.height - 1), z: 0),
                            sourceSize: MTLSize(width: min(rw, cur.texture.width - min(rx, cur.texture.width - 1)), height: min(rh, cur.texture.height - min(ry, cur.texture.height - 1)), depth: 1),
                            to: snap,
                            destinationSlice: 0,
                            destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                        blit.endEncoding()
                        backdropSnap = snap
                    }
                }

                let site = EffectSite(
                    index: effectCounter,
                    instance: inst,
                    mark: mark,
                    data: inst.uv,
                    scale: 1.0,
                    pixelFormat: cur.format,
                    origin: cur.origin,
                    pixelSize: (cur.texture.width, cur.texture.height),
                    inLayer: cur.isLayer,
                    srgbBlend: frame.srgbBlend,
                    backdrop: backdropSnap
                )

                if let bh = backdropHook {
                    bh(.backdrop(commandBuffer), site)
                }

                if hook != nil || backdropHook != nil {
                    let rpd = MTLRenderPassDescriptor()
                    rpd.colorAttachments[0].texture = cur.texture
                    rpd.colorAttachments[0].loadAction = .load
                    rpd.colorAttachments[0].storeAction = .store
                    if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                        let minX = max(0, Int(floorf(inst.rect.x - cur.origin.x)))
                        let minY = max(0, Int(floorf(inst.rect.y - cur.origin.y)))
                        let maxX = min(cur.texture.width, Int(ceilf(inst.rect.x + inst.rect.z - cur.origin.x)))
                        let maxY = min(cur.texture.height, Int(ceilf(inst.rect.y + inst.rect.w - cur.origin.y)))
                        if maxX > minX && maxY > minY {
                            enc.setScissorRect(MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
                            hook?(enc, site)
                            backdropHook?(.draw(enc), site)
                        }
                        enc.endEncoding()
                    }
                }
                effectCounter &+= 1
                continue
            }

            if kind == KIND_BACKDROP_BLUR {
                flushPendingUpTo(i)
                batchStart = i + 1
                if backdropBlurCount < MAX_BACKDROP_BLURS {
                    backdropBlurCount += 1
                    let cur = stack[stack.count - 1]
                    var layerGlobals = globals
                    layerGlobals.projection = SIMD4<Float>(cur.origin.x, cur.origin.y, Float(cur.texture.width), Float(cur.texture.height))
                    if let gBuf = uploader.ensureGlobalsBuffer(device: device, globals: layerGlobals) ?? .some(rootGlobalsBuffer) {
                        backdropBlur.encode(
                            device: device,
                            commandBuffer: commandBuffer,
                            source: cur.texture,
                            target: cur.texture,
                            targetFormat: cur.format,
                            instanceIndex: i,
                            instance: inst,
                            instanceBuffer: instanceBuffer,
                            globalsBuffer: gBuf,
                            viewport: SIMD2<Float>(Float(cur.texture.width), Float(cur.texture.height)),
                            originOffset: cur.origin
                        )
                    }
                }
                continue
            }
        }

        // Flush remaining batch & trailing surfaces on the root target
        flushPendingUpTo(instances.count)
        flushSurfacesBefore(instances.count + 1)
        if !frame.surfaces.isEmpty {
            surfaceRenderer?.trackSubmission(commandBuffer: commandBuffer)
        }
    }

    func renderOffscreen(
        _ frame: RenderFrame,
        surfaceRenderer: SurfaceRenderer?,
        commandQueue: MTLCommandQueue,
        hook: EffectHook?,
        backdropHook: EffectBackdropHook?
    ) throws -> Frame {
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
        guard let targetTex = device.makeTexture(descriptor: texDesc),
              let cmdBuf = commandQueue.makeCommandBuffer() else {
            throw MetalRenderer.RendererError.metalUnavailable
        }

        draw(
            frame: frame,
            into: targetTex,
            commandBuffer: cmdBuf,
            surfaceRenderer: surfaceRenderer,
            hook: hook,
            backdropHook: backdropHook
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

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
    /// Renders an upstream-parity `RenderFrame` into a `CAMetalDrawable` and presents it.
    public func draw(
        frame: RenderFrame,
        to drawable: CAMetalDrawable,
        hook: EffectHook? = nil,
        backdropHook: EffectBackdropHook? = nil
    ) {
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        let sr = acquireSurfaceRenderer(pixelFormat: drawable.texture.pixelFormat)
        renderEngine.draw(
            frame: frame,
            into: drawable.texture,
            commandBuffer: cmdBuf,
            surfaceRenderer: sr,
            hook: hook,
            backdropHook: backdropHook
        )
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Encodes a `RenderFrame` into `target` without committing (matches `render::Renderer::draw_range`).
    public func drawRange(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        let sr = acquireSurfaceRenderer(pixelFormat: target.pixelFormat)
        renderEngine.draw(
            frame: frame,
            into: target,
            commandBuffer: commandBuffer,
            surfaceRenderer: sr,
            hook: nil,
            backdropHook: nil
        )
    }

    /// Encodes a `RenderFrame` with an `EffectHook` callback (`render::Renderer::draw_range_with`).
    public func drawRangeWith(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        hook: EffectHook?
    ) {
        let sr = acquireSurfaceRenderer(pixelFormat: target.pixelFormat)
        renderEngine.draw(
            frame: frame,
            into: target,
            commandBuffer: commandBuffer,
            surfaceRenderer: sr,
            hook: hook,
            backdropHook: nil
        )
    }

    /// Encodes a `RenderFrame` with a two-phase `EffectBackdropHook` (`render::Renderer::draw_with_backdrop`).
    public func drawWithBackdrop(
        frame: RenderFrame,
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        hook: EffectBackdropHook?
    ) {
        let sr = acquireSurfaceRenderer(pixelFormat: target.pixelFormat)
        renderEngine.draw(
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
        let pixelFormat: MTLPixelFormat = frame.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        let sr = acquireSurfaceRenderer(pixelFormat: pixelFormat)
        return try renderEngine.renderOffscreen(
            frame,
            surfaceRenderer: sr,
            commandQueue: commandQueue,
            hook: hook,
            backdropHook: backdropHook
        )
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

    /// `#819` GPU memory give-back on window rest / occlusion.
    public func giveBack(all: Bool = false, residentCaches: Bool = false) {
        renderEngine.layersPool.giveBack(all: all, residentCaches: residentCaches)
        renderEngine.backdropBlur.giveBack()
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
}
#endif
