import Foundation
import RuneRef

#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore
#if canImport(simd)
import simd
#endif

/// Hardware-accelerated Metal instanced uber-quad renderer (`rune::MetalRenderer`).
///
/// Shares the exact 32-float `Primitive` layout and analytic SDF formulas with `RuneRef`,
/// rendering entire UI frames in a single instanced draw call (or split only across isolated
/// `layerBegin`/`layerEnd` offscreen passes).
public final class MetalRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipelineLinearSRGB: MTLRenderPipelineState
    private let pipelineGammaSRGB: MTLRenderPipelineState
    private let pipelineFloatLayer: MTLRenderPipelineState
    private let pipelineBlur: MTLRenderPipelineState
    private let pipelineCompositeLinear: MTLRenderPipelineState
    private let pipelineCompositeGamma: MTLRenderPipelineState
    private let pipelineCompositeFloat: MTLRenderPipelineState
    private let pipelineCompositeAddLinear: MTLRenderPipelineState
    private let pipelineCompositeAddGamma: MTLRenderPipelineState
    private let pipelineCompositeAddFloat: MTLRenderPipelineState
    private let computeSpringsPipeline: MTLComputePipelineState
    private let samplerLinear: MTLSamplerState

    public var hasCompiledExtendedShaders: Bool {
        _ = computeSpringsPipeline
        return renderEngine.hasCompiledShaders
    }

    public typealias GPUSpringTrack = Rune.GPUSpringTrack
    public typealias GPUSpringNode = Rune.GPUSpringNode

    private struct BlurUniforms {
        var bounds: SIMD4<Float>
        var params: SIMD4<Float>
    }

    private struct LayerCompositeUniforms {
        var rect: SIMD4<Float>
        var clip: SIMD4<Float>
        var radii: SIMD4<Float>
        var extra: SIMD4<Float>
        var vp: SIMD4<Float>
    }

    private struct AtlasTexture {
        var texels: [UInt8]
        var texture: MTLTexture
    }

    private var referenceGlyphPages: [AtlasTexture] = []
    private var referenceImagePages: [AtlasTexture] = []
    private var surfaceRenderer: SurfaceRenderer?
    internal let renderEngine: RenderFrameEngine

    public var activeSurfaceRenderer: SurfaceRenderer? { surfaceRenderer }

    internal func acquireSurfaceRenderer(pixelFormat: MTLPixelFormat) -> SurfaceRenderer? {
        if surfaceRenderer == nil {
            surfaceRenderer = try? SurfaceRenderer(device: device, pixelFormat: pixelFormat)
        }
        return surfaceRenderer
    }

    public enum RendererError: Error, CustomStringConvertible {
        case metalUnavailable
        case shaderCompileFailed(String)
        case missingCachedLayer(UInt64)
        case textureAllocationFailed(resource: String, width: Int, height: Int)

        public var description: String {
            switch self {
            case .metalUnavailable: return "No Metal device is available on this machine"
            case .shaderCompileFailed(let msg): return "Metal shader compilation failed: \(msg)"
            case .missingCachedLayer(let node): return "Rune layer \(node) is unavailable. Rebuild the frame on its drawing renderer."
            case let .textureAllocationFailed(resource, width, height): return "Metal could not allocate the \(width)×\(height) \(resource)"
            }
        }
    }

    deinit {
        renderEngine.layersPool.registerTracker(nil)
    }

    public init(device: MTLDevice? = nil) throws {
        guard let dev = device ?? MetalAdapterPicker.select(),
              let queue = dev.makeCommandQueue() else {
            throw RendererError.metalUnavailable
        }
        self.device = dev
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try ShaderLibraryCache.load(
                named: "legacy_rune",
                source: Self.mslSource,
                requiredFunction: "rune_vertex",
                on: dev
            )
        } catch {
            throw RendererError.shaderCompileFailed("\(error)")
        }

        guard let vertFn = library.makeFunction(name: "rune_vertex"),
              let fragFn = library.makeFunction(name: "rune_fragment"),
              let fsVertFn = library.makeFunction(name: "rune_fullscreen_vertex"),
              let blurFragFn = library.makeFunction(name: "rune_blur_fragment"),
              let compFragFn = library.makeFunction(name: "rune_layer_composite_fragment"),
              let springsComputeFn = library.makeFunction(name: "rune_springs_compute") else {
            throw RendererError.shaderCompileFailed("Missing shader entry points")
        }

        func buildPipeline(
            vert: MTLFunction,
            frag: MTLFunction,
            pixelFormat: MTLPixelFormat,
            blend: Bool = true,
            additive: Bool = false
        ) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = pixelFormat
            desc.colorAttachments[0].isBlendingEnabled = blend
            if blend {
                desc.colorAttachments[0].rgbBlendOperation = .add
                desc.colorAttachments[0].alphaBlendOperation = .add
                desc.colorAttachments[0].sourceRGBBlendFactor = .one
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                desc.colorAttachments[0].destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            }
            return try dev.makeRenderPipelineState(descriptor: desc)
        }

        self.pipelineLinearSRGB = try buildPipeline(vert: vertFn, frag: fragFn, pixelFormat: .bgra8Unorm_srgb)
        self.pipelineGammaSRGB = try buildPipeline(vert: vertFn, frag: fragFn, pixelFormat: .bgra8Unorm)
        self.pipelineFloatLayer = try buildPipeline(vert: vertFn, frag: fragFn, pixelFormat: .rgba16Float)

        self.pipelineBlur = try buildPipeline(vert: fsVertFn, frag: blurFragFn, pixelFormat: .rgba16Float, blend: false)

        self.pipelineCompositeLinear = try buildPipeline(vert: fsVertFn, frag: compFragFn, pixelFormat: .bgra8Unorm_srgb)
        self.pipelineCompositeGamma = try buildPipeline(vert: fsVertFn, frag: compFragFn, pixelFormat: .bgra8Unorm)
        self.pipelineCompositeFloat = try buildPipeline(vert: fsVertFn, frag: compFragFn, pixelFormat: .rgba16Float)

        self.pipelineCompositeAddLinear = try buildPipeline(vert: fsVertFn, frag: compFragFn, pixelFormat: .bgra8Unorm_srgb, additive: true)
        self.pipelineCompositeAddGamma = try buildPipeline(vert: fsVertFn, frag: compFragFn, pixelFormat: .bgra8Unorm, additive: true)
        self.pipelineCompositeAddFloat = try buildPipeline(vert: fsVertFn, frag: compFragFn, pixelFormat: .rgba16Float, additive: true)


        self.computeSpringsPipeline = try dev.makeComputePipelineState(function: springsComputeFn)

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        self.samplerLinear = dev.makeSamplerState(descriptor: sampDesc)!
        self.renderEngine = try RenderFrameEngine(device: dev)
        self.renderEngine.layersPool.drawingQueue = queue
    }

    /// Evaluates an array of `GPUSpringNode` tracks on the Metal GPU at `timeSeconds`.
    public func evaluateSpringsOnGPU(_ nodes: [GPUSpringNode], timeSeconds: Double) -> [SIMD4<Float>] {
        guard !nodes.isEmpty else { return [] }
        let whole = floor(timeSeconds)
        var splitTime = SIMD2<Float>(Float(whole), Float(timeSeconds - whole))
        let count = nodes.count
        guard let inBuf = device.makeBuffer(bytes: nodes, length: MemoryLayout<GPUSpringNode>.stride * count, options: .storageModeShared),
              let outBuf = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * count, options: .storageModeShared),
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            return []
        }
        enc.setComputePipelineState(computeSpringsPipeline)
        enc.setBuffer(inBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.setBytes(&splitTime, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        let tgSize = MTLSize(width: min(count, computeSpringsPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let ptr = outBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    /// Renders `scene` on the Metal GPU into an offscreen texture and reads back an RGBA8 `Frame`
    /// (for headless `--snap` PNG output and GPU-vs-`RuneRef` equivalence tests!).
    public func renderOffscreen(_ scene: RefScene, surfaces: [SurfaceDraw] = []) throws -> Frame {
        try validate(scene)

        let w = scene.width
        let h = scene.height
        let pixelFormat: MTLPixelFormat = scene.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: w,
            height: h,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let targetTex = device.makeTexture(descriptor: texDesc) else {
            throw RendererError.textureAllocationFailed(resource: "render target", width: w, height: h)
        }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { throw RendererError.metalUnavailable }

        try encodeMainPass(scene: scene, surfaces: surfaces, into: targetTex, commandBuffer: cmdBuf)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        if let error = cmdBuf.error { throw error }

        // Read back BGRA8 bytes and swizzle to RGBA8
        var bgra = Array<UInt8>(repeating: 0, count: w * h * 4)
        targetTex.getBytes(
            &bgra,
            bytesPerRow: w * 4,
            from: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0
        )
        var rgba = Array<UInt8>(repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let b = bgra[i]
            let g = bgra[i + 1]
            let r = bgra[i + 2]
            let a = bgra[i + 3]
            // Unpremultiply if partially transparent so straight RGBA matches `RuneRef`
            if a > 0 && a < 255 {
                let af = Float(a) / 255.0
                if scene.srgbBlend {
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

    /// Renders `scene` directly into a `CAMetalDrawable` for 60/120Hz native window presentation.
    @discardableResult
    public func render(scene: RefScene, surfaces: [SurfaceDraw] = [], to drawable: CAMetalDrawable) -> Result<Void, Error> {
        Result {
            guard let cmdBuf = commandQueue.makeCommandBuffer() else { throw RendererError.metalUnavailable }
            try encode(scene: scene, surfaces: surfaces, into: drawable.texture, commandBuffer: cmdBuf)
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }

    /// Encodes `scene` into an arbitrary caller-owned `MTLTexture` using `commandBuffer` without committing.
    public func encode(scene: RefScene, surfaces: [SurfaceDraw] = [], into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try validate(scene)
        try encodeMainPass(scene: scene, surfaces: surfaces, into: target, commandBuffer: commandBuffer)
    }

    private func validate(_ scene: RefScene) throws {
        try MetalTextureLimits.validate(width: scene.width, height: scene.height, resource: "render target", on: device)
        for page in 0..<max(1, scene.glyphPages.count) {
            let single = scene.glyphPages.isEmpty
            let atlas = single ? scene.glyphs : scene.glyphPages[page]
            try MetalTextureLimits.validate(width: atlas.width, height: atlas.height,
                                            resource: single ? "glyph atlas" : "glyph atlas page \(page)", on: device)
        }
        for page in 0..<max(1, scene.imagePages.count) {
            let single = scene.imagePages.isEmpty
            let atlas = single ? scene.images : scene.imagePages[page]
            try MetalTextureLimits.validate(width: atlas.width, height: atlas.height,
                                            resource: single ? "image atlas" : "image atlas page \(page)", on: device)
        }
        try scene.validate()
    }

    /// A frame may be encoded before an earlier submission completes. Never overwrite a texture
    /// still referenced by that frame. Unchanged immutable page storage shares its Metal texture.
    private func atlasTexture(width: Int, height: Int, texels: [UInt8], format: MTLPixelFormat,
                              resource: String, previous: AtlasTexture?) throws -> AtlasTexture {
        if let previous, previous.texture.width == width, previous.texture.height == height,
           previous.texture.pixelFormat == format,
           texels.withUnsafeBufferPointer({ current in
               previous.texels.withUnsafeBufferPointer { $0.baseAddress == current.baseAddress }
           }) {
            return previous
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RendererError.textureAllocationFailed(resource: resource, width: width, height: height)
        }
        texels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: base, bytesPerRow: width * (format == .r8Unorm ? 1 : 4))
            }
        }
        return AtlasTexture(texels: texels, texture: texture)
    }

    private func uploadAtlases(_ scene: RefScene) throws {
        referenceGlyphPages = try (0..<max(1, scene.glyphPages.count)).map { index in
            let atlas = scene.glyphAtlas(forPage: index)
            let previous = referenceGlyphPages.indices.contains(index) ? referenceGlyphPages[index] : nil
            return try atlasTexture(width: atlas.width, height: atlas.height, texels: atlas.texels,
                                    format: .r8Unorm, resource: "glyph atlas page \(index)", previous: previous)
        }
        let format: MTLPixelFormat = scene.srgbBlend ? .rgba8Unorm : .rgba8Unorm_srgb
        referenceImagePages = try (0..<max(1, scene.imagePages.count)).map { index in
            let atlas = scene.imageAtlas(forPage: index)
            let previous = referenceImagePages.indices.contains(index) ? referenceImagePages[index] : nil
            return try atlasTexture(width: atlas.width, height: atlas.height, texels: atlas.texels,
                                    format: format, resource: "image atlas page \(index)", previous: previous)
        }
    }

    private func makeFloatTexture(width: Int, height: Int, resource: String) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RendererError.textureAllocationFailed(resource: resource, width: width, height: height)
        }
        return texture
    }

    private func runBoxBlurPass(
        source: MTLTexture,
        dest: MTLTexture,
        bounds: SIMD4<Float>,
        dirX: Float,
        dirY: Float,
        radius: Int,
        viewport: SIMD2<Float>,
        commandBuffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dest
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipelineBlur)
        var vp = viewport
        var u = BlurUniforms(
            bounds: bounds,
            params: SIMD4<Float>(dirX, dirY, Float(radius), 0)
        )
        enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func blurLayerTexture(
        _ inputTex: MTLTexture,
        width: Int,
        height: Int,
        radius: Float,
        rectBounds: SIMD4<Float>,
        viewport: SIMD2<Float>,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let r = min(24, max(1, Int(radius.rounded())))
        let minX = Float(max(0, Int(floorf(rectBounds.x)) - r))
        let minY = Float(max(0, Int(floorf(rectBounds.y)) - r))
        let maxX = Float(min(width - 1, Int(ceilf(rectBounds.x + rectBounds.z)) + r))
        let maxY = Float(min(height - 1, Int(ceilf(rectBounds.y + rectBounds.w)) + r))
        if minX > maxX || minY > maxY { return inputTex }

        let scratch = try makeFloatTexture(width: width, height: height, resource: "blur intermediate")
        let ping = try makeFloatTexture(width: width, height: height, resource: "blur result")
        let b = SIMD4<Float>(minX, minY, maxX, maxY)
        // Copy full frame first with radius 0 into `ping`, then run 2 separable H+V box blur iterations
        let fullBounds = SIMD4<Float>(0, 0, Float(width - 1), Float(height - 1))
        runBoxBlurPass(source: inputTex, dest: ping, bounds: fullBounds, dirX: 1, dirY: 0, radius: 0, viewport: viewport, commandBuffer: commandBuffer)
        for _ in 0..<2 {
            runBoxBlurPass(source: ping, dest: scratch, bounds: b, dirX: 1, dirY: 0, radius: r, viewport: viewport, commandBuffer: commandBuffer)
            runBoxBlurPass(source: scratch, dest: ping, bounds: b, dirX: 0, dirY: 1, radius: r, viewport: viewport, commandBuffer: commandBuffer)
        }
        return ping
    }

    @discardableResult
    internal func renderScene(_ scene: RefScene, surfaces: [SurfaceDraw] = [], into target: MTLTexture, commandBuffer: MTLCommandBuffer) -> Result<Void, Error> {
        Result { try encode(scene: scene, surfaces: surfaces, into: target, commandBuffer: commandBuffer) }
    }

    private func encodeMainPass(scene: RefScene, surfaces: [SurfaceDraw] = [], into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try uploadAtlases(scene)

        let w = scene.width
        let h = scene.height
        let viewport = SIMD2<Float>(Float(w), Float(h))
        let ca = Double(RefShader.clamp01(scene.clearColor.w))
        let rootClear = MTLClearColorMake(
            Double(scene.clearColor.x) * ca,
            Double(scene.clearColor.y) * ca,
            Double(scene.clearColor.z) * ca,
            ca
        )

        var activeSurfRenderer: SurfaceRenderer? = nil
        if !surfaces.isEmpty {
            if surfaceRenderer == nil {
                surfaceRenderer = try? SurfaceRenderer(device: device, pixelFormat: target.pixelFormat)
            }
            if let sr = surfaceRenderer {
                sr.srgbBlend = scene.srgbBlend
                try sr.prepare(draws: surfaces, viewport: (UInt32(w), UInt32(h))).get()
                if !sr.isEmpty {
                    activeSurfRenderer = sr
                }
            }
        }
        var surfaceCursor = 0
        var backdropCount = 0

        struct TargetLevel {
            var texture: MTLTexture
            var clearColor: MTLClearColor
            var cleared: Bool
            var pending: [Primitive]
            var layerPrim: Primitive?
        }

        func flush(_ level: inout TargetLevel) {
            guard !level.cleared || !level.pending.isEmpty else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = level.texture
            pass.colorAttachments[0].loadAction = level.cleared ? .load : .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = level.clearColor
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                let pipe: MTLRenderPipelineState
                switch level.texture.pixelFormat {
                case .bgra8Unorm: pipe = pipelineGammaSRGB
                case .rgba16Float: pipe = pipelineFloatLayer
                default: pipe = pipelineLinearSRGB
                }
                enc.setRenderPipelineState(pipe)
                if !level.pending.isEmpty {
                    var vp = viewport
                    let byteLen = level.pending.count * MemoryLayout<Primitive>.stride
                    if let primBuf = device.makeBuffer(bytes: level.pending, length: byteLen, options: .storageModeShared) {
                        enc.setVertexBuffer(primBuf, offset: 0, index: 0)
                        enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                        enc.setFragmentBuffer(primBuf, offset: 0, index: 0)
                        enc.setFragmentSamplerState(samplerLinear, index: 0)
                        var glyphPage = 0
                        var imagePage = 0
                        var start = 0
                        func drawRun(through end: Int) {
                            guard end > start else { return }
                            enc.setFragmentTexture(referenceGlyphPages[glyphPage].texture, index: 0)
                            enc.setFragmentTexture(referenceImagePages[imagePage].texture, index: 1)
                            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                               instanceCount: end - start, baseInstance: start)
                        }
                        for (index, prim) in level.pending.enumerated() {
                            let requestedGlyph = prim.kind == .glyph ? prim.glyphPage : glyphPage
                            let glyph = referenceGlyphPages.indices.contains(requestedGlyph) ? requestedGlyph : 0
                            let image = prim.kind == .image ? prim.imagePage : imagePage
                            guard glyph != glyphPage || image != imagePage else { continue }
                            drawRun(through: index)
                            if referenceImagePages.indices.contains(image) {
                                start = index
                                glyphPage = glyph
                                imagePage = image
                            } else {
                                // A missing page is transparent; intervening flat-color draws still use the last bindings.
                                start = index + 1
                            }
                        }
                        drawRun(through: level.pending.count)
                    }
                }
                enc.endEncoding()
            }
            level.pending.removeAll(keepingCapacity: true)
            level.cleared = true
        }

        var stack: [TargetLevel] = [
            TargetLevel(texture: target, clearColor: rootClear, cleared: false, pending: [], layerPrim: nil)
        ]

        func flushSurfaces(upTo primIndex: UInt32) {
            guard let sr = activeSurfRenderer else { return }
            let total = sr.count
            guard surfaceCursor < total, sr.beforeInstance(at: surfaceCursor) <= primIndex else { return }
            flush(&stack[stack.count - 1])
            let tex = stack[stack.count - 1].texture
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tex
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                while surfaceCursor < total && sr.beforeInstance(at: surfaceCursor) <= primIndex {
                    sr.draw(encoder: enc, index: surfaceCursor, pixelFormat: tex.pixelFormat)
                    surfaceCursor += 1
                }
                enc.endEncoding()
            }
        }

        for (primIndex, prim) in scene.primitives.enumerated() {
            flushSurfaces(upTo: UInt32(primIndex))
            switch prim.kind {
            case .layerBegin:
                flush(&stack[stack.count - 1])
                let layerTex = try makeFloatTexture(width: w, height: h, resource: "layer")
                stack.append(
                    TargetLevel(
                        texture: layerTex,
                        clearColor: MTLClearColorMake(0, 0, 0, 0),
                        cleared: false,
                        pending: [],
                        layerPrim: prim
                    )
                )

            case .layerEnd:
                guard stack.count > 1 else { continue }
                var finished = stack.removeLast()
                flush(&finished)
                guard let lp = finished.layerPrim else { continue }
                var srcTex = finished.texture
                let blurRad = max(0, lp.params.w)
                if blurRad >= 0.5 {
                    srcTex = try blurLayerTexture(srcTex, width: w, height: h, radius: blurRad, rectBounds: lp.rect, viewport: viewport, commandBuffer: commandBuffer)
                }

                // Ensure destination target is cleared before compositing
                if !stack[stack.count - 1].cleared {
                    flush(&stack[stack.count - 1])
                }
                let dstTex = stack[stack.count - 1].texture
                let isAdd = lp.params.z >= 0.5
                let compPipe: MTLRenderPipelineState
                switch dstTex.pixelFormat {
                case .bgra8Unorm: compPipe = isAdd ? pipelineCompositeAddGamma : pipelineCompositeGamma
                case .rgba16Float: compPipe = isAdd ? pipelineCompositeAddFloat : pipelineCompositeFloat
                default: compPipe = isAdd ? pipelineCompositeAddLinear : pipelineCompositeLinear
                }

                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = dstTex
                pass.colorAttachments[0].loadAction = .load
                pass.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                    enc.setRenderPipelineState(compPipe)
                    var vp = viewport
                    var u = LayerCompositeUniforms(
                        rect: lp.rect,
                        clip: lp.clip,
                        radii: .zero,
                        extra: SIMD4<Float>(RefShader.clamp01(lp.params.x), lp.turn, 0, 0),
                        vp: SIMD4<Float>(viewport.x, viewport.y, 0, 0)
                    )
                    enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                    enc.setFragmentTexture(srcTex, index: 0)
                    enc.setFragmentSamplerState(samplerLinear, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }

            case .backdropBlur:
                guard prim.params.x > 0, prim.backdropOpacity > 0, backdropCount < MAX_BACKDROP_BLURS else { continue }
                backdropCount += 1
                flush(&stack[stack.count - 1])
                let texture = stack[stack.count - 1].texture
                var instance = RenderInstance(rect: prim.rect, radii: prim.radii, fill: SIMD4(0, 0, 0, prim.backdropOpacity),
                                              params: SIMD4(prim.params.x, KIND_BACKDROP_BLUR, 0, prim.params.w),
                                              clip: SIMD4(prim.clip.x, prim.clip.y, prim.clip.x + prim.clip.z, prim.clip.y + prim.clip.w))
                var globals = RenderGlobals(viewport: viewport)
                renderEngine.backdropBlur.encode(device: device, commandBuffer: commandBuffer, source: texture,
                                                 target: texture, targetFormat: texture.pixelFormat,
                                                 instance: instance, originOffset: .zero) { encoder in
                    encoder.setVertexBytes(&instance, length: MemoryLayout<RenderInstance>.stride, index: 0)
                    encoder.setVertexBytes(&globals, length: MemoryLayout<RenderGlobals>.stride, index: 1)
                }

            default:
                stack[stack.count - 1].pending.append(prim)
            }
        }

        flushSurfaces(upTo: UInt32.max)
        flush(&stack[0])
        activeSurfRenderer?.trackSubmission(commandBuffer: commandBuffer)
    }

    // MARK: - Metal Shading Language (MSL) Uber-Shader matching `RefShader` 1:1

    internal static let mslSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Primitive {
        float4 rect;
        float4 radii;
        float4 fill;
        float4 border;
        float4 params;
        float4 uv;
        float4 clip;
        float4 fade;
        float2 fadeOrigin;
        float turn;
        float _pad;
    };

    struct Varyings {
        float4 position [[position]];
        uint instanceId [[flat]];
    };

    vertex Varyings rune_vertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        constant Primitive *prims [[buffer(0)]],
        constant float2 &viewport [[buffer(1)]]
    ) {
        Primitive p = prims[iid];
        float2 center = p.rect.xy + p.rect.zw * 0.5;
        float2 halfExt = p.rect.zw * 0.5 + float2(2.0);
        if (p.turn != 0.0) {
            float cs = abs(cos(p.turn));
            float sn = abs(sin(p.turn));
            halfExt = float2(
                p.rect.z * 0.5 * cs + p.rect.w * 0.5 * sn + 2.5,
                p.rect.z * 0.5 * sn + p.rect.w * 0.5 * cs + 2.5
            );
        }
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float2 px = center + corner * halfExt;
        float2 ndc = float2((px.x / viewport.x) * 2.0 - 1.0, 1.0 - (px.y / viewport.y) * 2.0);
        Varyings out;
        out.position = float4(ndc, 0.0, 1.0);
        out.instanceId = iid;
        return out;
    }

    static inline float pick_radius(float2 p, float4 radii) {
        if (p.x < 0.0) { return p.y < 0.0 ? radii.x : radii.w; }
        else           { return p.y < 0.0 ? radii.y : radii.z; }
    }

    static inline float sd_box(float2 p, float2 b, float4 radii) {
        float rawR = pick_radius(p, radii);
        float maxR = max(0.0, min(b.x, b.y));
        if (rawR >= 0.0) {
            float r = min(rawR, maxR);
            float2 q = abs(p) - b + r;
            return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        } else {
            float r = min(-rawR, maxR);
            if (r <= 1e-4) {
                float2 q = abs(p) - b;
                return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
            }
            float2 q = abs(p) - b + r;
            float std_sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            float2 u = max(abs(p) - (b - r * 1.528665), 0.0) / (r * 1.528665);
            if (u.x > 0.0 && u.y > 0.0) {
                float se = (pow(pow(u.x, 2.4) + pow(u.y, 2.4), 1.0 / 2.4) - 1.0) * (r * 0.85);
                float w = saturate(min(u.x, u.y) * 2.0);
                return std_sd * (1.0 - w * 0.35) + se * (w * 0.35);
            }
            return std_sd;
        }
    }

    static inline float box_cov(float sd) { return saturate(0.5 - sd); }

    static inline float erf_approx(float x) {
        float s = x < 0.0 ? -1.0 : 1.0;
        float ax = abs(x);
        float t = 1.0 / (1.0 + 0.3275911 * ax);
        float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-ax * ax);
        return s * y;
    }

    static inline float gaussian_shadow(float2 p, float2 halfSize, float radius, float blur) {
        if (blur <= 0.5) {
            return box_cov(sd_box(p, halfSize, float4(radius)));
        }
        float sigma = max(blur * 0.5, 0.25);
        float r = min(max(0.0, radius), min(halfSize.x, halfSize.y));
        float invSqrt2Sigma = 1.0 / (1.41421356 * sigma);
        float low = max(-halfSize.y, p.y - 3.0 * sigma);
        float high = min(halfSize.y, p.y + 3.0 * sigma);
        if (low >= high) return 0.0;
        float step = (high - low) * 0.25;
        float integral = 0.0;
        for (int i = 0; i < 4; ++i) {
            float y = low + (float(i) + 0.5) * step;
            float cy = max(0.0, abs(y) - (halfSize.y - r));
            float xHalf = (halfSize.x - r) + sqrt(max(0.0, r * r - cy * cy));
            float xInt = 0.5 * (erf_approx((p.x + xHalf) * invSqrt2Sigma) - erf_approx((p.x - xHalf) * invSqrt2Sigma));
            float dy = (y - p.y) / sigma;
            float weight = 0.3989422804 * exp(-0.5 * dy * dy) / sigma;
            integral += xInt * weight * step;
        }
        return saturate(integral);
    }

    static inline float ring_arc(float2 p, float2 b, float r) {
        float cr = min(max(0.0, r), min(b.x, b.y));
        float sx = max(0.0, b.x - cr);
        float sy = max(0.0, b.y - cr);
        float topLen = 2.0 * sx;
        float sideLen = 2.0 * sy;
        float cornerLen = 1.5707963268 * cr;
        if (p.y <= -sy && abs(p.x) <= sx) return p.x + sx;
        if (p.x > sx && p.y < -sy) return topLen + saturate(atan2(p.x - sx, -(p.y + sy)) / 1.5707963268) * cornerLen;
        if (p.x >= sx && abs(p.y) <= sy) return topLen + cornerLen + (p.y + sy);
        if (p.x > sx && p.y > sy) return topLen + cornerLen + sideLen + saturate(atan2(p.y - sy, p.x - sx) / 1.5707963268) * cornerLen;
        if (p.y >= sy && abs(p.x) <= sx) return topLen + 2.0 * cornerLen + sideLen + (sx - p.x);
        if (p.x < -sx && p.y > sy) return 2.0 * topLen + 2.0 * cornerLen + sideLen + saturate(atan2(-(p.x + sx), p.y - sy) / 1.5707963268) * cornerLen;
        if (p.x <= -sx && abs(p.y) <= sy) return 2.0 * topLen + 3.0 * cornerLen + sideLen + (sy - p.y);
        return 2.0 * topLen + 3.0 * cornerLen + 2.0 * sideLen + saturate(atan2(-(p.y + sy), -(p.x + sx)) / 1.5707963268) * cornerLen;
    }

    static inline float4 image_texel(texture2d<float> atlas, uint2 pixel) {
        float4 texel = atlas.read(pixel);
        return float4(texel.rgb * texel.a, texel.a);
    }

    static inline float4 sample_image(texture2d<float> atlas, float4 uv, float4 source, float2 coords) {
        float2 size = float2(atlas.get_width(), atlas.get_height());
        float2 start = saturate(uv.xy) * size;
        float2 end = saturate(uv.zw) * size;
        float2 lower = min(start, end);
        float2 upper = max(start, end);
        if (all(source.zw > source.xy)) {
            lower = clamp(source.xy, float2(0), size);
            upper = clamp(source.zw, float2(0), size);
        }
        // Normalizing an integer texel edge can round it just outside its atlas slot.
        float2 lo = min(floor(lower + lower * 1.1920929e-7), size - 1.0);
        float2 hi = clamp(ceil(upper - upper * 1.1920929e-7) - 1.0, lo, size - 1.0);
        float2 pixel = clamp(mix(start, end, coords) - 0.5, lo, hi);
        uint2 first = uint2(floor(pixel));
        uint2 last = min(first + uint2(1), uint2(hi));
        float2 f = fract(pixel);
        return mix(mix(image_texel(atlas, first), image_texel(atlas, uint2(last.x, first.y)), f.x),
                   mix(image_texel(atlas, uint2(first.x, last.y)), image_texel(atlas, last), f.x), f.y);
    }

    fragment float4 rune_fragment(
        Varyings in [[stage_in]],
        constant Primitive *prims [[buffer(0)]],
        texture2d<float> glyphAtlas [[texture(0)]],
        texture2d<float> imageAtlas [[texture(1)]],
        sampler samp [[sampler(0)]]
    ) {
        Primitive prim = prims[in.instanceId];
        float2 frag = in.position.xy;

        if (prim.clip.z <= 0.0 || prim.clip.w <= 0.0) return float4(0.0);
        float clipX = saturate(min(frag.x - prim.clip.x + 0.5, (prim.clip.x + prim.clip.z) - frag.x + 0.5));
        float clipY = saturate(min(frag.y - prim.clip.y + 0.5, (prim.clip.y + prim.clip.w) - frag.y + 0.5));
        float fadeCov = clipX * clipY;
        if (fadeCov <= 0.0) return float4(0.0);

        if (prim.fade.z != 0.0) {
            float d = dot(frag - prim.fadeOrigin, prim.fade.xy) * prim.fade.z;
            fadeCov *= prim.fade.w + (1.0 - prim.fade.w) * saturate(d);
            if (fadeCov <= 0.0) return float4(0.0);
        }

        float2 center = prim.rect.xy + prim.rect.zw * 0.5;
        float2 halfSize = prim.rect.zw * 0.5;
        float2 localP = frag - center;
        if (prim.turn != 0.0) {
            float cs = cos(-prim.turn);
            float sn = sin(-prim.turn);
            localP = float2(localP.x * cs - localP.y * sn, localP.x * sn + localP.y * cs);
        }

        int kind = int(rint(prim.params.y));
        float4 outPremul = float4(0.0);

        if (kind == 0) {
            float dOuter = sd_box(localP, halfSize, prim.radii);
            float outerCov = box_cov(dOuter);
            if (outerCov <= 0.0) return float4(0.0);
            float dInner = dOuter - 10.0;
            if (prim.params.x < 0.0) {
                float4 s = prim.uv;
                float2 shift = float2((s.w - s.y) * 0.5, (s.x - s.z) * 0.5);
                float2 iHalf = max(float2(0.0), halfSize - float2((s.w + s.y) * 0.5, (s.x + s.z) * 0.5));
                float4 avgS = float4((s.x + s.w) * 0.5, (s.x + s.y) * 0.5, (s.z + s.y) * 0.5, (s.z + s.w) * 0.5);
                float4 iRad = select(min(float4(0.0), prim.radii + avgS), max(float4(0.0), prim.radii - avgS), prim.radii >= 0.0);
                dInner = sd_box(localP - shift, iHalf, iRad);
            } else if (prim.params.x > 0.0) {
                float bw = prim.params.x;
                float2 iHalf = max(float2(0.0), halfSize - bw);
                float4 iRad = select(min(float4(0.0), prim.radii + bw), max(float4(0.0), prim.radii - bw), prim.radii >= 0.0);
                dInner = sd_box(localP, iHalf, iRad);
            }
            if (prim.border.w <= 0.0001) {
                float a = prim.fill.w * outerCov;
                outPremul = float4(prim.fill.rgb * a, a);
            } else {
                float innerCov = box_cov(dInner);
                float fillCov = (prim.border.w >= 0.999) ? box_cov((dOuter + dInner) * 0.5) : outerCov;
                float ba = prim.border.w * max(0.0, outerCov - innerCov);
                float fa = prim.fill.w * fillCov;
                float3 rgb = prim.border.rgb * ba + prim.fill.rgb * (fa * (1.0 - ba));
                outPremul = float4(rgb, ba + fa * (1.0 - ba));
            }
        } else if (kind == 1) {
            float4 boxRect = (prim.border.z > 0.0 && prim.border.w > 0.0) ? prim.border : prim.rect;
            float spread = prim.params.z;
            float2 sCenter = boxRect.xy + boxRect.zw * 0.5 + prim.uv.xy;
            float2 sHalf = max(float2(0.0), boxRect.zw * 0.5 + spread);
            float r = abs(pick_radius(frag - sCenter, prim.radii)) + spread;
            float cov = gaussian_shadow(frag - sCenter, sHalf, max(0.0, r), prim.params.x);
            if (prim.params.w > 0.5) {
                float2 cCenter = boxRect.xy + boxRect.zw * 0.5;
                cov *= (1.0 - box_cov(sd_box(frag - cCenter, boxRect.zw * 0.5, prim.radii)));
            }
            float a = prim.fill.w * cov;
            outPremul = float4(prim.fill.rgb * a, a);
        } else if (kind == 2) {
            float cov;
            if (prim.params.z == 1.0 && prim.turn == 0.0) {
                float2 offset = frag - prim.rect.xy;
                if (any(offset < 0.0) || any(offset >= prim.rect.zw)) return float4(0.0);
                float2 size = float2(glyphAtlas.get_width(), glyphAtlas.get_height());
                float2 start = prim.uv.xy * size;
                float2 texel = floor(start + abs(start) * 1.1920929e-7) + floor(offset);
                if (any(texel < 0.0) || any(texel >= size)) return float4(0.0);
                cov = glyphAtlas.read(uint2(texel)).r;
            } else {
                float2 uNorm = (localP + halfSize) / max(prim.rect.zw, float2(1e-4));
                if (uNorm.x < 0.0 || uNorm.x > 1.0 || uNorm.y < 0.0 || uNorm.y > 1.0) return float4(0.0);
                cov = glyphAtlas.sample(samp, mix(prim.uv.xy, prim.uv.zw, uNorm)).r;
            }
            if (prim.params.w > 0.0 && abs(prim.params.w - 1.0) > 1e-3) {
                cov = pow(saturate(cov), prim.params.w);
            }
            float a = prim.fill.w * cov;
            outPremul = float4(prim.fill.rgb * a, a);
        } else if (kind == 3) {
            float outerCov = box_cov(sd_box(localP, halfSize, prim.radii));
            if (outerCov <= 0.0) return float4(0.0);
            float spread = prim.params.z;
            float2 iHalf = max(float2(0.0), halfSize - spread);
            float r = max(0.0, abs(pick_radius(localP - prim.uv.xy, prim.radii)) - spread);
            float lit = gaussian_shadow(localP - prim.uv.xy, iHalf, r, prim.params.x);
            float a = prim.fill.w * outerCov * saturate(1.0 - lit);
            outPremul = float4(prim.fill.rgb * a, a);
        } else if (kind == 4) {
            float outerCov = box_cov(sd_box(localP, halfSize, prim.radii));
            if (outerCov <= 0.0) return float4(0.0);
            float2 dir = float2(cos(prim.params.z), sin(prim.params.z));
            float maxExt = abs(dir.x) * halfSize.x + abs(dir.y) * halfSize.y;
            float t = maxExt > 1e-4 ? saturate(0.5 + dot(localP, dir) / (2.0 * maxExt)) : 0.5;
            float4 col = mix(prim.fill, prim.border, t);
            if (prim.params.x > 0.0) {
                float2 innerHalf = max(float2(0.0), halfSize - prim.params.x);
                float4 innerRadii = max(float4(0.0), abs(prim.radii) - prim.params.x);
                outerCov = max(0.0, outerCov - box_cov(sd_box(localP, innerHalf, innerRadii)));
            }
            float a = col.w * outerCov;
            outPremul = float4(col.rgb * a, a);
        } else if (kind == 5) {
            float2 aPt = prim.uv.xy;
            float2 bPt = prim.uv.zw;
            float2 ab = bPt - aPt;
            float len2 = dot(ab, ab);
            float effW = max(prim.params.x, 1.0);
            float weight = saturate(prim.params.x);
            float halfW = effW * 0.5;
            float cov = 0.0;
            if (len2 < 1e-6) {
                cov = saturate(0.5 - (length(frag - aPt) - halfW)) * weight;
            } else if (prim.params.z >= 0.5) {
                float t = saturate(dot(frag - aPt, ab) / len2);
                cov = saturate(0.5 - (length(frag - (aPt + ab * t)) - halfW)) * weight;
            } else {
                float len = sqrt(len2);
                float2 dir = ab / len;
                float2 n = float2(-dir.y, dir.x);
                float2 rel = frag - (aPt + bPt) * 0.5;
                float2 q = float2(abs(dot(rel, dir)) - len * 0.5, abs(dot(rel, n)) - halfW);
                float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
                cov = saturate(0.5 - d) * weight;
            }
            float alpha = prim.fill.w * cov;
            outPremul = float4(prim.fill.rgb * alpha, alpha);
        } else if (kind == 6) {
            float2 v0 = prim.uv.xy;
            float2 v1 = prim.uv.zw;
            float2 v2 = prim.fadeOrigin;
            float area2 = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x);
            if (abs(area2) < 1e-5) return float4(0.0);
            float sgn = area2 > 0.0 ? 1.0 : -1.0;
            float2 verts[3] = { v0, v1, v2 };
            int aaMask = int(rint(prim.params.x));
            float cov = 1.0;
            for (int i = 0; i < 3; ++i) {
                float2 va = verts[i];
                float2 vb = verts[(i + 1) % 3];
                float2 e = vb - va;
                float len = length(e);
                if (len < 1e-5) return float4(0.0);
                float d = (((frag.x - va.x) * e.y - (frag.y - va.y) * e.x) * sgn) / len;
                if ((aaMask & (1 << i)) != 0) {
                    cov = min(cov, saturate(0.5 - d));
                    if (cov <= 0.0) return float4(0.0);
                } else {
                    float2 oe = e * sgn;
                    bool owns = (oe.y > 0.0) || (oe.y == 0.0 && oe.x < 0.0);
                    if (d > 0.0 || (d == 0.0 && !owns)) return float4(0.0);
                }
            }
            float alpha = prim.fill.w * cov;
            outPremul = float4(prim.fill.rgb * alpha, alpha);
        } else if (kind == 7) {
            float outerCov = box_cov(sd_box(localP, halfSize, prim.radii));
            if (outerCov <= 0.0) return float4(0.0);
            float2 uNorm = saturate((localP + halfSize) / max(prim.rect.zw, float2(1e-4)));
            float4 tex = sample_image(imageAtlas, prim.uv, prim.border, uNorm);
            outPremul = tex * float4(prim.fill.rgb, 1.0) * (prim.fill.a * outerCov);
        } else if (kind == 10) {
            float bw = max(0.5, prim.params.x);
            float outerCov = box_cov(sd_box(localP, halfSize, prim.radii));
            if (outerCov <= 0.0) return float4(0.0);
            float2 iHalf = max(float2(0.0), halfSize - bw);
            float4 iRad = max(float4(0.0), abs(prim.radii) - bw);
            float ringCov = max(0.0, outerCov - box_cov(sd_box(localP, iHalf, iRad)));
            if (ringCov <= 0.0) return float4(0.0);
            float avgR = abs(pick_radius(localP, prim.radii));
            float arc = ring_arc(localP, max(float2(0.0), halfSize - bw * 0.5), max(0.0, avgR - bw * 0.5));
            float period = max(prim.params.z + prim.params.w, 1.0);
            float pos = fmod(arc + prim.uv.x, period);
            if (pos < 0.0) pos += period;
            float dCov = max(min(saturate(pos + 0.5), saturate(prim.params.z - pos + 0.5)), saturate(pos - period + prim.params.z + 0.5));
            float alpha = prim.fill.w * ringCov * dCov;
            outPremul = float4(prim.fill.rgb * alpha, alpha);
        } else if (kind == 11) {
            float outerCov = box_cov(sd_box(localP, halfSize, prim.radii));
            if (outerCov <= 0.0) return float4(0.0);
            float2 rel = (frag - prim.uv.xy) / max(prim.uv.zw, float2(1e-3));
            float4 col = mix(prim.fill, prim.border, saturate(length(rel)));
            float a = col.w * outerCov;
            outPremul = float4(col.rgb * a, a);
        }

        return outPremul * fadeCov;
    }

    struct FullscreenVaryings {
        float4 position [[position]];
    };

    struct BlurUniforms {
        float4 bounds;
        float4 params;
    };

    struct LayerCompositeUniforms {
        float4 rect;
        float4 clip;
        float4 radii;
        float4 extra;
        float4 vp;
    };

    vertex FullscreenVaryings rune_fullscreen_vertex(
        uint vid [[vertex_id]],
        constant float2 &viewport [[buffer(0)]]
    ) {
        (void)viewport;
        float2 ndc = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        FullscreenVaryings out;
        out.position = float4(ndc, 0.0, 1.0);
        return out;
    }

    fragment float4 rune_blur_fragment(
        FullscreenVaryings in [[stage_in]],
        constant BlurUniforms &u [[buffer(0)]],
        texture2d<float, access::read> srcTex [[texture(0)]]
    ) {
        int2 px = int2(floor(in.position.xy));
        int minX = int(u.bounds.x);
        int minY = int(u.bounds.y);
        int maxX = int(u.bounds.z);
        int maxY = int(u.bounds.w);
        int r = int(rint(u.params.z));
        if (r <= 0 || px.x < minX || px.x > maxX || px.y < minY || px.y > maxY) {
            return srcTex.read(uint2(px));
        }
        int dx = int(rint(u.params.x));
        int dy = int(rint(u.params.y));
        float4 sum = float4(0.0);
        for (int k = -r; k <= r; ++k) {
            int sx = clamp(px.x + k * dx, minX, maxX);
            int sy = clamp(px.y + k * dy, minY, maxY);
            sum += srcTex.read(uint2(sx, sy));
        }
        return sum / float(2 * r + 1);
    }

    fragment float4 rune_layer_composite_fragment(
        FullscreenVaryings in [[stage_in]],
        constant LayerCompositeUniforms &u [[buffer(0)]],
        texture2d<float> layerTex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float2 frag = in.position.xy;
        if (u.clip.z <= 0.0 || u.clip.w <= 0.0) return float4(0.0);
        float clipX = saturate(min(frag.x - u.clip.x + 0.5, (u.clip.x + u.clip.z) - frag.x + 0.5));
        float clipY = saturate(min(frag.y - u.clip.y + 0.5, (u.clip.y + u.clip.w) - frag.y + 0.5));
        float clipCov = clipX * clipY;
        if (clipCov <= 0.0) return float4(0.0);

        float2 minB = min(u.rect.xy, u.clip.xy) - float2(2.0);
        float2 maxB = max(u.rect.xy + u.rect.zw, u.clip.xy + u.clip.zw) + float2(2.0);
        if (frag.x < minB.x || frag.x > maxB.x || frag.y < minB.y || frag.y > maxB.y) {
            return float4(0.0);
        }

        float opacity = u.extra.x;
        float turn = u.extra.y;
        float4 srcSample;
        if (turn != 0.0) {
            float2 center = u.rect.xy + u.rect.zw * 0.5;
            float2 rel = frag - center;
            float cs = cos(-turn);
            float sn = sin(-turn);
            float2 srcPos = center + float2(rel.x * cs - rel.y * sn, rel.x * sn + rel.y * cs);
            if (srcPos.x < 0.0 || srcPos.x >= u.vp.x || srcPos.y < 0.0 || srcPos.y >= u.vp.y) {
                return float4(0.0);
            }
            srcSample = layerTex.sample(samp, srcPos / u.vp.xy);
        } else {
            srcSample = layerTex.read(uint2(floor(frag)));
        }
        return srcSample * (opacity * clipCov);
    }

    fragment float4 rune_backdrop_fragment(
        FullscreenVaryings in [[stage_in]],
        constant LayerCompositeUniforms &u [[buffer(0)]],
        texture2d<float, access::read> snapTex [[texture(0)]],
        texture2d<float, access::read> blurredTex [[texture(1)]]
    ) {
        int2 px = int2(floor(in.position.xy));
        float4 dst = snapTex.read(uint2(px));
        if (u.clip.z <= 0.0 || u.clip.w <= 0.0) return dst;
        float2 frag = in.position.xy;
        float clipX = saturate(min(frag.x - u.clip.x + 0.5, (u.clip.x + u.clip.z) - frag.x + 0.5));
        float clipY = saturate(min(frag.y - u.clip.y + 0.5, (u.clip.y + u.clip.w) - frag.y + 0.5));
        float clipCov = clipX * clipY;
        if (clipCov <= 0.0) return dst;

        float2 center = u.rect.xy + u.rect.zw * 0.5;
        float2 halfSize = u.rect.zw * 0.5;
        float cov = box_cov(sd_box(frag - center, halfSize, u.radii)) * clipCov;
        if (cov <= 0.0) return dst;
        float4 blurred = blurredTex.read(uint2(px));
        return dst * (1.0 - cov) + blurred * cov;
    }

    struct SpringTrack {
        float4 abcd;
        float2 rates;
        float goal;
        uint kind;
        float2 start;
        float duration;
        float pad;
    };

    struct SpringNode {
        SpringTrack x;
        SpringTrack y;
        SpringTrack opacity;
    };

    inline float spring_exp(float x) {
        if (x < -87.0) return 0.0;
        float xc = clamp(x, -87.0, 88.0);
        float k = round(xc * 1.4426950408889634);
        float r = fma(-k, 0.0000014286068, fma(-k, 0.69314575, xc));
        float r2 = r * r;
        float a = 1.0 + r;
        float b = fma(r, 1.0 / 6.0, 0.5);
        float c = fma(r, 1.0 / 120.0, 1.0 / 24.0);
        float p = fma(r2, fma(r2, fma(r2, 1.0 / 720.0, c), b), a);
        return p * as_type<float>(uint(int(k) + 127) << 23u);
    }

    inline float2 spring_sample(SpringTrack s, float2 time) {
        float whole = float(int(time.x) - int(s.start.x));
        float t = max(whole + (time.y - s.start.y), 0.0);
        if (s.kind == 0u || t >= s.duration) return float2(s.goal, 0.0);
        float4 c = s.abcd;
        if (s.kind == 1u) {
            float e = exp(-s.rates.x * t);
            float co = cos(s.rates.y * t);
            float si = sin(s.rates.y * t);
            return float2(s.goal + e * (c.x * co + c.y * si), e * (c.z * co + c.w * si));
        }
        if (s.kind == 2u) {
            float e = exp(-s.rates.x * t);
            return float2(s.goal + (c.x + c.y * t) * e, (c.z + c.w * t) * e);
        }
        float e1 = spring_exp(c.z * t);
        float e2 = spring_exp(c.w * t);
        return float2(s.goal + (c.x * e1 + c.y * e2), c.x * c.z * e1 + c.y * c.w * e2);
    }

    kernel void rune_springs_compute(
        device const SpringNode *nodes [[buffer(0)]],
        device float4 *outputs [[buffer(1)]],
        constant float2 &time [[buffer(2)]],
        uint gid [[thread_position_in_grid]]
    ) {
        SpringNode n = nodes[gid];
        float x = spring_sample(n.x, time).x;
        float y = spring_sample(n.y, time).x;
        float op = clamp(spring_sample(n.opacity, time).x, 0.0, 1.0);
        outputs[gid] = float4(x, y, op, 0.0);
    }
    """
}
#endif
