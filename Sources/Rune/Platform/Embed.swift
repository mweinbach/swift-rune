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

/// Hosts a Rune `Runtime` inside a caller-owned `CAMetalLayer` without creating an app window
/// (`platform::embed::LayerHost`).
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
        let rt = Runtime<State>(
            state: spec.makeState(),
            viewport: initialSize,
            pixelScale: resolvedScale,
            systemDark: spec.dark ?? dark,
            reducedMotion: reducedMotion,
            onKey: spec.onKey,
            view: spec.view
        )
        // The capture presets (`RUNE_CONTRAST`, `RUNE_INCREASE_CONTRAST`) as `tooling::runtime_for` applies them (#981).
        rt.applyCapturePresets()
        self.runtime = rt
        self.config = config
        self.lastViewport = initialSize
        self.lastScale = resolvedScale
        self.layer = layer

        if let layer {
            let dev = layer.device ?? MTLCreateSystemDefaultDevice()
            layer.device = dev
            layer.pixelFormat = .bgra8Unorm
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
        self.runtime = Runtime<State>(
            state: spec.makeState(),
            viewport: initialSize,
            pixelScale: resolvedScale,
            systemDark: spec.dark ?? dark,
            reducedMotion: reducedMotion,
            onKey: spec.onKey,
            view: spec.view
        )
        // The capture presets (`RUNE_CONTRAST`, `RUNE_INCREASE_CONTRAST`) as `tooling::runtime_for` applies them (#981).
        self.runtime.applyCapturePresets()
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
        runtime.viewport = clampedViewport
        runtime.pixelScale = resolvedScale
        runtime.markNeedsCommit()

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
        let startNs = DispatchTime.now().uptimeNanoseconds

        let customScene = compositorHook?(runtime, now)
        let shouldDraw = !hasRenderedFirstFrame || runtime.hasPendingCommit || runtime.isAnimating || customScene != nil
        var drew = false
        if shouldDraw {
            let scene = customScene ?? runtime.frame(at: now)
            hasRenderedFirstFrame = true
            #if canImport(Metal) && canImport(QuartzCore)
            if let layer {
                if let renderer, let drawable = layer.nextDrawable() {
                    renderer.render(scene: scene, to: drawable)
                    drew = true
                }
            } else {
                drew = true
            }
            #else
            drew = true
            #endif
        }

        let wakeAfterSecs: Double? = runtime.nextWakeDeadline(after: now).map { max(0.0, $0 - now) }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startNs
        return EmbedFrame(
            drew: drew,
            animating: runtime.isAnimating,
            wakeAfterSecs: wakeAfterSecs,
            cpuUs: elapsedNs / 1000
        )
    }

    /// Mutates app state directly inside the host's runtime.
    public func update(_ body: (inout State, inout Tx) -> Void) {
        var tx = Tx()
        body(&runtime.state, &tx)
        runtime.markNeedsCommit()
    }
}
