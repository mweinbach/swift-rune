#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore

extension MetalRenderer {
    /// Presents the default UI or the window's compositor, in the same transaction as native material changes.
    func present<State>(frame: RenderFrame, drawable: CAMetalDrawable, compositor: AnyCompositor<State>?,
                        runtime: Runtime<State>, dt: Float, updateMilliseconds: Double, synchronized: Bool) -> Int {
        if let error = renderEngine.selectCache(for: frame, viewport: (drawable.texture.width, drawable.texture.height)) {
            RuneStandardIO.error("Could not present Rune frame: \(error)\n")
            return 0
        }
        if synchronized {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        defer { if synchronized { CATransaction.commit() } }
        guard let compositor, let buffer = commandQueue.makeCommandBuffer() else {
            if case let .failure(error) = draw(frame: frame, to: drawable, synchronized: synchronized) {
                RuneStandardIO.error("Could not present Rune frame: \(error)\n")
                return 0
            }
            return 1
        }
        let count: Int
        do {
            count = try encodeCompositor(compositor, frame: frame, into: drawable.texture, commandBuffer: buffer,
                                         runtime: runtime, dt: dt, updateMilliseconds: updateMilliseconds)
        } catch {
            RuneStandardIO.error("Could not present Rune frame: \(error)\n")
            return 0
        }
        if synchronized {
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
        return count
    }

    /// Encodes a custom compositor into a window drawable or an offscreen capture texture.
    func encodeCompositor<State>(_ compositor: AnyCompositor<State>, frame: RenderFrame,
                                 into texture: MTLTexture, commandBuffer: MTLCommandBuffer,
                                 runtime: Runtime<State>, dt: Float, updateMilliseconds: Double) throws -> Int {
        var drawError: (any Error)?
        func drawUI(hook: EffectHook? = nil) {
            guard drawError == nil else { return }
            if case let .failure(error) = encodeUI(frame: frame, into: texture, commandBuffer: commandBuffer, hook: hook) {
                drawError = error
            }
        }
        let context = CompositorFrame(
            deviceKey: DeviceKey(rawValue: device.registryID), pixelSize: (texture.width, texture.height),
            dt: dt, updateMilliseconds: updateMilliseconds, srgbBlend: frame.srgbBlend, runtime: runtime,
            device: device, commandQueue: commandQueue, commandBuffer: commandBuffer, targetTexture: texture,
            pixelFormat: texture.pixelFormat, renderer: self,
            drawUI: { drawUI() }
        )
        context.installMetalEffects { hook in
            drawUI(hook: hook)
        }
        defer { context.endFrame() }
        compositor.render(frame: context)
        if !compositor.drawsOwnContent && context.uiDrawCount == 0 { context.drawUI() }
        if let drawError { throw drawError }
        return context.uiDrawCount
    }
}

extension FrameReports {
    func presented(_ frame: RenderFrame, at time: Double, started: Double, updateMs: Double, drawCount: Int,
                   committed: Bool, runtime: Runtime<State>, compositor: AnyCompositor<State>?) {
        let total = (CACurrentMediaTime() - started) * 1000
        record(FrameEncoded(outcome: .drawn, frameMs: total, updateMs: updateMs, encodeMs: max(0, total - updateMs),
                            committed: committed, primitives: frame.instances.count,
                            glyphs: frame.instances.reduce(0) { $0 + ($1.params.y == KIND_GLYPH ? 1 : 0) },
                            animating: runtime.isAnimating, compositorAnimating: compositor?.isAnimating ?? false,
                            drawCount: drawCount, compositorSummary: compositor?.summary(), at: time))
        _ = runtime.updateIf(at: time) { state, tx in flush(state: &state, tx: &tx, at: time) }
        inspect(runtime)
    }
}
#endif
