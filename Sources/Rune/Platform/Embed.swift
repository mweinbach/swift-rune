import Foundation
import RuneMotion
import RuneRef

#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore
#endif

/// Warms Metal shader compilation off the first embedded paint (`platform/embed.rs::prewarm`).
public enum EmbedPrewarm {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didPrewarm = false

    /// Compiles Rune's Metal shader pipelines once if Metal is available; returns `true` when ready.
    @discardableResult
    public static func prewarm() -> Bool {
        lock.lock()
        if didPrewarm {
            lock.unlock()
            return true
        }
        lock.unlock()

        #if canImport(Metal) && canImport(QuartzCore)
        guard let device = MTLCreateSystemDefaultDevice(),
              (try? MetalRenderer(device: device)) != nil else {
            return false
        }
        lock.lock()
        didPrewarm = true
        lock.unlock()
        return true
        #else
        return false
        #endif
    }
}

/// Outcome of rendering one frame inside a `LayerHost` (`platform::embed::EmbedFrame`).
public struct EmbedFrame: Sendable, Equatable {
    /// True when the layer drew a frame.
    public var drew: Bool
    /// True when spring, scroll, or live motion is active and another frame should follow.
    public var animating: Bool
    /// Seconds until the next scheduled animation/tooltip/enterDelay wake, if any.
    public var wakeAfterSecs: Double?
    /// CPU time spent rendering this frame, in microseconds.
    public var cpuUs: UInt64

    public init(drew: Bool, animating: Bool, wakeAfterSecs: Double?, cpuUs: UInt64) {
        self.drew = drew
        self.animating = animating
        self.wakeAfterSecs = wakeAfterSecs
        self.cpuUs = cpuUs
    }
}

/// Hosts a Rune runtime inside a caller's rendering loop.
public final class LayerHost<State> {
    public let runtime: Runtime<State>
    public let config: EmbedHostConfig

    #if canImport(Metal) && canImport(QuartzCore)
    public let layer: CAMetalLayer?
    private let renderer: MetalRenderer?
    #endif

    private var compositorHook: ((Runtime<State>, Double) -> RefScene?)?
    private var lastViewport: Vec2
    private var lastScale: Float
    private var hasRenderedFirstFrame = false
    private weak var lastPresenter: AnyObject?
    private var scheduledWake: Double?

    private static func makeRuntime(spec: AppSpec<State>, viewport: Vec2, scale: Float,
                                    dark: Bool, reducedMotion: Bool) -> Runtime<State> {
        HeadlessRunner.registerFonts(spec.fonts)
        let rt = Runtime<State>(state: spec.makeState(), viewport: viewport, pixelScale: scale,
                                systemDark: spec.dark ?? dark, reducedMotion: reducedMotion,
                                onKey: spec.onKey, view: spec.view)
        rt.srgbBlend = spec.srgbBlend
        rt.windowTitle = spec.title
        rt.poll = spec.poll
        rt.onAppFileDrop = spec.onFileDrop
        rt.onFileDrop = spec.onFileDropPhase
        rt.applyCapturePresets()
        spec.setup?(rt.waker)
        return rt
    }

    #if canImport(Metal) && canImport(QuartzCore)
    /// Attaches a `Runtime<State>` backed by `spec` to `layer`.
    public init(
        layer: CAMetalLayer?,
        spec: AppSpec<State>,
        scale: Float = 2.0,
        dark: Bool = true,
        reducedMotion: Bool = false,
        config: EmbedHostConfig = EmbedHostConfig()
    ) throws {
        let initialSize = (config.initialSize.x > 0 && config.initialSize.y > 0)
            ? config.initialSize
            : spec.size
        let resolvedScale = max(0.5, scale)
        self.runtime = Self.makeRuntime(spec: spec, viewport: initialSize, scale: resolvedScale,
                                        dark: dark, reducedMotion: reducedMotion)
        self.config = config
        self.lastViewport = initialSize
        self.lastScale = resolvedScale
        self.layer = layer

        if let layer {
            let dev = layer.device ?? MTLCreateSystemDefaultDevice()
            layer.device = dev
            layer.pixelFormat = spec.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
            layer.framebufferOnly = false
            layer.isOpaque = !config.transparentBackground
            layer.contentsScale = CGFloat(resolvedScale)
            layer.drawableSize = CGSize(
                width: max(1, CGFloat(roundf(initialSize.x * resolvedScale))),
                height: max(1, CGFloat(roundf(initialSize.y * resolvedScale)))
            )
            self.renderer = try MetalRenderer(device: dev)
        } else {
            self.renderer = nil
        }
    }

    /// Convenience headless initializer (for tests or offscreen embedding without a `CAMetalLayer`).
    public convenience init(
        spec: AppSpec<State>,
        scale: Float = 2.0,
        dark: Bool = true,
        reducedMotion: Bool = false,
        config: EmbedHostConfig = EmbedHostConfig()
    ) throws {
        try self.init(
            layer: nil,
            spec: spec,
            scale: scale,
            dark: dark,
            reducedMotion: reducedMotion,
            config: config
        )
    }
    #else
    public init(
        spec: AppSpec<State>,
        scale: Float = 2.0,
        dark: Bool = true,
        reducedMotion: Bool = false,
        config: EmbedHostConfig = EmbedHostConfig()
    ) {
        let initialSize = (config.initialSize.x > 0 && config.initialSize.y > 0)
            ? config.initialSize
            : spec.size
        let resolvedScale = max(0.5, scale)
        self.runtime = Self.makeRuntime(spec: spec, viewport: initialSize, scale: resolvedScale,
                                        dark: dark, reducedMotion: reducedMotion)
        self.config = config
        self.lastViewport = initialSize
        self.lastScale = resolvedScale
    }
    #endif

    /// Installs an optional custom compositor hook evaluated per frame before presenting.
    @discardableResult
    public func withCompositor(_ hook: @escaping (Runtime<State>, Double) -> RefScene?) -> Self {
        self.compositorHook = hook
        return self
    }

    /// Updates viewport dimensions (in points) and backing scale factor.
    public func resize(viewport: Vec2, scale: Float? = nil) {
        let clampedViewport = Vec2(max(1, viewport.x), max(1, viewport.y))
        let resolvedScale = max(0.5, scale ?? lastScale)
        lastViewport = clampedViewport
        lastScale = resolvedScale
        runtime.setViewport(clampedViewport, pixelScale: resolvedScale)

        #if canImport(Metal) && canImport(QuartzCore)
        if let layer {
            layer.contentsScale = CGFloat(resolvedScale)
            layer.drawableSize = CGSize(
                width: max(1, CGFloat(roundf(clampedViewport.x * resolvedScale))),
                height: max(1, CGFloat(roundf(clampedViewport.y * resolvedScale)))
            )
        }
        #endif
    }

    /// Evaluates one frame at `now` seconds and presents to the attached `CAMetalLayer` when needed.
    @discardableResult
    public func frame(at now: Double) -> EmbedFrame {
        evaluateFrame(at: now, presenter: self, forceRedraw: false) { customScene in
            #if canImport(Metal) && canImport(QuartzCore)
            if let layer {
                guard let renderer, let drawable = layer.nextDrawable() else { return false }
                if let customScene {
                    renderer.render(scene: customScene, to: drawable)
                } else {
                    renderer.draw(frame: renderer.frame(runtime, at: now), to: drawable)
                }
                return true
            }
            #endif
            if customScene == nil { _ = runtime.frame(at: now) }
            return true
        }
    }

    fileprivate func evaluateFrame(
        at now: Double, presenter: AnyObject, forceRedraw: Bool,
        present: (RefScene?) throws -> Bool
    ) rethrows -> EmbedFrame {
        let startNs = RuneExecutionContext.uptimeNanoseconds

        let customScene = compositorHook?(runtime, now)
        let wakeDue = scheduledWake.map { now >= $0 } ?? false
        let shouldDraw = forceRedraw || lastPresenter !== presenter || wakeDue || !hasRenderedFirstFrame || runtime.hasPendingCommit
            || runtime.isAnimating || runtime.livePending || runtime.poll != nil || customScene != nil
        var drew = false
        if shouldDraw {
            // Retry even when building the scene consumed the runtime's dirty flag.
            hasRenderedFirstFrame = false
            drew = try present(customScene)
            hasRenderedFirstFrame = drew
            if drew { lastPresenter = presenter }
        }

        scheduledWake = runtime.nextWakeDeadline(after: now)
        let wakeAfterSecs = scheduledWake.map { max(0.0, $0 - now) }
        let elapsedNs = RuneExecutionContext.uptimeNanoseconds &- startNs
        return EmbedFrame(
            drew: drew,
            animating: runtime.isAnimating,
            wakeAfterSecs: wakeAfterSecs,
            cpuUs: elapsedNs / 1000
        )
    }

    /// Mutates app state directly inside the host's runtime.
    public func update(_ body: (inout State, inout Tx) -> Void) {
        runtime.update(body)
    }
}

#if canImport(CRuneGL)
/// Draws embedded Rune layers into a caller-owned OpenGL 3.3 or OpenGL ES 3 context.
/// The caller binds its framebuffer, invokes `draw`, and presents its own swapchain.
/// Construct, draw and close on the owning thread with the same context current.
public final class OpenGLLayerRenderer {
    public typealias ProcResolver = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private let renderer: PortableGLRenderer
    public var adapter: DisplayGpuAdapter { renderer.adapter }

    public init(resolve: @escaping ProcResolver, isGLES: Bool = false,
                shaderSource: ((String) throws -> String)? = nil) throws {
        renderer = try PortableGLRenderer(resolve: resolve, isGLES: isGLES, shaderSource: shaderSource)
    }

    /// Active layer storage, GPU passes, and retained-cache hit and eviction counters.
    public func layerStats() -> LayerStats { renderer.layerStats() }

    /// Limits retained layer texture storage in bytes. Shrinking the budget evicts
    /// entries immediately. A zero budget keeps drawing using transient targets.
    public func setLayerCacheBudget(_ bytes: Int) { renderer.setLayerCacheBudget(bytes) }

    /// Force a redraw when the containing framebuffer has been cleared or replaced.
    @discardableResult
    public func draw<State>(_ host: LayerHost<State>, at time: Double, forceRedraw: Bool = false) throws -> EmbedFrame {
        try host.evaluateFrame(at: time, presenter: self, forceRedraw: forceRedraw) { customScene in
            if let customScene {
                try renderer.draw(customScene)
            } else {
                try renderer.draw(renderer.frame(host.runtime, at: time))
            }
            return true
        }
    }

    /// Release the GL resources before detaching or destroying the context.
    public func close() { renderer.close() }

    /// Release the CPU-side resources after the driver already destroyed the context.
    public func abandon() { renderer.abandon() }
}
#endif
