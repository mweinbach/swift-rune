#if canImport(CRuneGL)
import CRuneGL
#if canImport(Metal)
import Metal
#endif

/// A C callback cannot capture a Swift closure. This object lives for one synchronous GL draw.
private final class OpenGLEffectDispatch {
    let frame: RenderFrame
    let resolve: RuneGLResolve
    let hook: CompositorEffectHook
    var failure: (any Error)?
    private var nextInstance = 0
    private var effectIndex: UInt32 = 0
    private var layers: [(opacity: Float, turn: Float)] = []

    init(frame: RenderFrame, resolve: @escaping RuneGLResolve, hook: @escaping CompositorEffectHook) {
        self.frame = frame
        self.resolve = resolve
        self.hook = hook
    }

    func draw(index: Int, framebuffer: UInt32, backdrop: UInt32, width: Int, height: Int,
              origin: SIMD2<Float>) -> Int32 {
        guard frame.instances.indices.contains(index), nextInstance <= index else { return 0 }
        for i in nextInstance..<index {
            let item = frame.instances[i]
            if item.params.y == KIND_LAYER {
                let inherited = layers.last ?? (opacity: 1, turn: 0)
                layers.append((inherited.opacity * item.fill.w,
                               item.border.y == 0 ? inherited.turn : item.border.y))
            } else if item.params.y == KIND_LAYER_END {
                _ = layers.popLast()
            }
        }
        nextInstance = index + 1
        let item = frame.instances[index]
        let mark: UInt32
        if frame.marks.indices.contains(index) {
            mark = frame.marks[index]
        } else {
            let lo = UInt16(exactly: item.border.x) ?? 0
            let hi = UInt16(exactly: item.border.y) ?? 0
            mark = UInt32(lo) | UInt32(hi) << 16
        }
        let size = (width: width, height: height)
        let target = OpenGLCompositorTarget(framebuffer: framebuffer, pixelSize: size,
                                            resolve: resolve, backdropTexture: backdrop == 0 ? nil : backdrop)
        let layer = layers.last ?? (opacity: 1, turn: 0)
        #if canImport(Metal)
        let site = EffectSite(index: effectIndex, instance: item, mark: mark, data: item.uv,
                              scale: item.params.w, pixelFormat: .invalid, origin: origin, pixelSize: size,
                              inLayer: !layers.isEmpty, opacity: layer.opacity, turn: layer.turn,
                              srgbBlend: frame.srgbBlend, backdrop: nil)
        let pass = CompositorEffectPass(site: site, openGL: target, metalEncoder: nil)
        #else
        let site = EffectSite(index: effectIndex, instance: item, mark: mark, data: item.uv,
                              scale: item.params.w, origin: origin, pixelSize: size,
                              inLayer: !layers.isEmpty, opacity: layer.opacity, turn: layer.turn,
                              srgbBlend: frame.srgbBlend)
        let pass = CompositorEffectPass(site: site, openGL: target)
        #endif
        effectIndex &+= 1
        do {
            try hook(pass)
            return 1
        } catch {
            failure = error
            return 0
        }
    }
}

private func drawOpenGLEffect(_ user: UnsafeMutableRawPointer?, _ index: Int, _ framebuffer: UInt32,
                              _ backdrop: UInt32, _ width: Int32, _ height: Int32,
                              _ originX: Int32, _ originY: Int32) -> Int32 {
    guard let user else { return 0 }
    let dispatch = Unmanaged<OpenGLEffectDispatch>.fromOpaque(user).takeUnretainedValue()
    return dispatch.draw(index: index, framebuffer: framebuffer, backdrop: backdrop,
                         width: Int(width), height: Int(height), origin: SIMD2(Float(originX), Float(originY)))
}

extension PortableGLRenderer {
    @discardableResult
    func draw<State>(_ frame: RenderFrame, compositor: AnyCompositor<State>?, runtime: Runtime<State>,
                     at time: Double, updateMilliseconds: Double = 0, frameDelta: Float? = nil) throws -> Int {
        guard let compositor else {
            try draw(frame)
            return 1
        }
        guard !compositor.features.contains(.requiresMetal) else {
            throw RenderError("The app compositor requires Metal. The active rendering context is \(adapter).")
        }
        guard let handle else { throw RenderError("Rune GL renderer is closed") }
        let framebuffer = rune_gl_draw_framebuffer(handle)
        let size = (width: frame.width, height: frame.height)
        let dt = frameDelta ?? Float(max(0, time - (previousCompositorTime ?? time)))
        previousCompositorTime = time
        var failure: (any Error)?

        func drawUI(_ hook: CompositorEffectHook?) throws {
            rune_gl_bind_draw_framebuffer(handle, framebuffer)
            if let hook {
                let dispatch = OpenGLEffectDispatch(frame: frame, resolve: resolver, hook: hook)
                rune_gl_set_effect_hook(handle, drawOpenGLEffect, Unmanaged.passUnretained(dispatch).toOpaque())
                defer { rune_gl_set_effect_hook(handle, nil, nil) }
                do { try withExtendedLifetime(dispatch) { try draw(frame) } }
                catch { throw dispatch.failure ?? error }
            } else {
                try draw(frame)
            }
        }

        let context = CompositorFrame(deviceKey: compositorDeviceKey, pixelSize: size, dt: dt,
                                      updateMilliseconds: updateMilliseconds, srgbBlend: frame.srgbBlend,
                                      runtime: runtime, drawUI: {
            guard failure == nil else { return }
            do { try drawUI(nil) } catch { failure = error }
        })
        context.openGL = OpenGLCompositorTarget(framebuffer: framebuffer, pixelSize: size,
                                                resolve: resolver, backdropTexture: nil)
        context.drawUIWithEffects = { hook in try drawUI(hook) }
        defer {
            context.endFrame()
            rune_gl_bind_draw_framebuffer(handle, framebuffer)
        }
        compositor.render(frame: context)
        if !compositor.drawsOwnContent && context.uiDrawCount == 0 { context.drawUI() }
        if let failure { throw failure }
        return context.uiDrawCount
    }
}
#endif
