import Foundation
import RuneRef
#if canImport(Metal)
import Metal
#endif

enum OffscreenRenderError: Error, CustomStringConvertible {
    case unavailable(String)
    case capture(String)

    var description: String {
        switch self {
        case let .unavailable(message), let .capture(message): return message
        }
    }
}

/// Synchronous GPU frame capture through the host's Metal or GL driver.
/// Create, render, and release on the same thread. On GL, release nested renderers in reverse creation order.
public final class OffscreenGPURenderer {
    public let adapter: DisplayGpuAdapter
    let deviceKey: DeviceKey
    #if canImport(Metal)
    let metal: MetalRenderer
    private var submissionTarget: MTLTexture?
    #elseif canImport(CRuneOffscreenGL)
    private let context: OffscreenGLContext
    let gl: PortableGLRenderer
    #endif

    public init(reportAdapter: Bool = false) throws {
        #if canImport(Metal)
        do {
            metal = try MetalRenderer()
        } catch MetalRenderer.RendererError.metalUnavailable {
            throw OffscreenRenderError.unavailable("No Metal device is available for frame capture")
        }
        deviceKey = DeviceKey(rawValue: metal.device.registryID)
        adapter = DisplayGpuAdapter(backend: .metal, device: metal.device.name)
        adapter.reportIfRequested()
        #elseif canImport(CRuneOffscreenGL)
        let context = try OffscreenGLContext()
        do {
            gl = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES)
        } catch {
            context.close()
            throw error
        }
        self.context = context
        deviceKey = DeviceKey.next()
        adapter = gl.adapter
        #else
        throw OffscreenRenderError.unavailable("This platform has no offscreen GPU renderer")
        #endif
        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        if reportAdapter && ProcessInfo.processInfo.environment["RUNE_GPU_INFO"] != "1" {
            RuneStandardIO.error("Rune GPU: \(adapter)\n")
        }
        #endif
    }

    static func selected(for args: ToolingArgs) throws -> OffscreenGPURenderer? {
        let report = ProcessInfo.processInfo.environment["RUNE_GPU_INFO"] == "1"
        if args.forceCPU && !args.requireGPU {
            if report { RuneStandardIO.error("Rune CPU: reference renderer selected\n") }
            return nil
        }
        do {
            return try OffscreenGPURenderer(reportAdapter: args.requireGPU)
        } catch OffscreenRenderError.unavailable(let reason) where !args.requireGPU {
            if report { RuneStandardIO.error("Rune CPU: offscreen GPU unavailable (\(reason))\n") }
            return nil
        }
    }

    /// Paint a runtime using this device's resident layers before drawing the frame.
    public func frame<State>(_ runtime: Runtime<State>, at time: Double) throws -> RenderFrame {
        #if canImport(Metal)
        return metal.frame(runtime, at: time)
        #elseif canImport(CRuneOffscreenGL)
        try context.makeCurrent()
        return gl.frame(runtime, at: time)
        #else
        return runtime.renderFrame(at: time)
        #endif
    }

    public func layerStats() -> LayerStats {
        #if canImport(Metal)
        return metal.layerStats()
        #elseif canImport(CRuneOffscreenGL)
        return gl.layerStats()
        #else
        return LayerStats()
        #endif
    }

    public func setLayerCacheBudget(_ bytes: Int) throws {
        #if canImport(Metal)
        metal.setLayerCacheBudget(bytes)
        #elseif canImport(CRuneOffscreenGL)
        try context.makeCurrent()
        gl.setLayerCacheBudget(bytes)
        #else
        throw OffscreenRenderError.unavailable("This platform has no offscreen GPU renderer")
        #endif
    }

    public func renderOffscreen(_ scene: RefScene, surfaces: [SurfaceDraw] = []) throws -> Frame {
        #if canImport(Metal)
        return try metal.renderOffscreen(scene, surfaces: surfaces)
        #elseif canImport(CRuneOffscreenGL)
        return try context.withFramebuffer(width: scene.width, height: scene.height) {
            try gl.draw(scene, surfaces: surfaces)
        }
        #else
        throw OffscreenRenderError.unavailable("This platform has no offscreen GPU renderer")
        #endif
    }

    public func renderOffscreen(_ frame: RenderFrame) throws -> Frame {
        #if canImport(Metal)
        return try metal.renderOffscreen(frame)
        #elseif canImport(CRuneOffscreenGL)
        return try context.withFramebuffer(width: frame.width, height: frame.height) {
            try gl.draw(frame)
        }
        #else
        throw OffscreenRenderError.unavailable("This platform has no offscreen GPU renderer")
        #endif
    }

    /// Draws into a reusable target and waits for completion without reading pixels.
    /// The returned instant marks command submission, before the completion wait.
    @discardableResult
    package func submitOffscreen(_ frame: RenderFrame) throws -> ContinuousClock.Instant {
        #if canImport(Metal)
        guard frame.width > 0, frame.height > 0, frame.width <= 16_384, frame.height <= 16_384 else {
            throw RefSceneError.invalidDimensions(width: frame.width, height: frame.height)
        }
        let format: MTLPixelFormat = frame.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        if submissionTarget?.width != frame.width || submissionTarget?.height != frame.height
            || submissionTarget?.pixelFormat != format {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: frame.width, height: frame.height, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            submissionTarget = metal.device.makeTexture(descriptor: descriptor)
        }
        guard let target = submissionTarget, let commands = metal.commandQueue.makeCommandBuffer() else {
            throw OffscreenRenderError.capture("Cannot allocate the offscreen Metal target or command buffer")
        }
        try metal.drawRange(frame: frame, into: target, commandBuffer: commands).get()
        commands.commit()
        let submitted = ContinuousClock.now
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        return submitted
        #elseif canImport(CRuneOffscreenGL)
        try context.bindFramebuffer(width: frame.width, height: frame.height)
        try gl.draw(frame)
        return try context.finishSubmission(gl.handle)
        #else
        throw OffscreenRenderError.unavailable("This platform has no offscreen GPU renderer")
        #endif
    }

    func renderOffscreen<State>(_ frame: RenderFrame, compositor: AnyCompositor<State>,
                                runtime: Runtime<State>, at time: Double, dt: Float) throws -> (Frame, Int) {
        #if canImport(Metal)
        var count = 0
        let pixels = try metal.renderEngine.renderOffscreen(frame, commandQueue: metal.commandQueue) { target, commands in
            count = try metal.encodeCompositor(compositor, frame: frame, into: target, commandBuffer: commands,
                                           runtime: runtime, dt: dt, updateMilliseconds: 0)
        }
        return (pixels, count)
        #elseif canImport(CRuneOffscreenGL)
        var count = 0
        let pixels = try context.withFramebuffer(width: frame.width, height: frame.height) {
            count = try gl.draw(frame, compositor: compositor, runtime: runtime, at: time, frameDelta: dt)
        }
        return (pixels, count)
        #else
        throw OffscreenRenderError.unavailable("This platform has no offscreen GPU renderer")
        #endif
    }

    deinit {
        #if !canImport(Metal) && canImport(CRuneOffscreenGL)
        do {
            try context.makeCurrent()
            gl.close()
        } catch {
            gl.abandon()
        }
        context.close()
        #endif
    }
}
