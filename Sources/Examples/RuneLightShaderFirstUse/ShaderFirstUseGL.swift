#if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
import CRuneGL
import Foundation
import Rune
import RuneFX
import RuneLight

extension RuneLightShaderFirstUseApp {
    static func runGL(snapPath: String?) throws {
        let clock = ContinuousClock()
        func elapsedMs(_ start: ContinuousClock.Instant) -> Double {
            let d = (clock.now - start).components
            return Double(d.seconds) * 1e3 + Double(d.attoseconds) * 1e-15
        }

        let startDevice = clock.now
        let context = try OffscreenGLContext()
        defer { context.close() }
        let resolve = OffscreenGLContext.resolve
        let deviceMs = elapsedMs(startDevice)
        let size = 64
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        func diagnostic() -> NSError {
            let message = String(decoding: error.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            return NSError(domain: "RuneLightShaderFirstUse", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let pass = rune_gl_pass_open(resolve, &error, capacity) else { throw diagnostic() }
        defer { rune_gl_pass_close(pass) }
        func target(_ format: RuneGLPassFormat) throws -> RuneGLPassTarget {
            var result = RuneGLPassTarget()
            guard rune_gl_pass_target(pass, format, Int32(size), Int32(size), 1, &result, &error, capacity) != 0 else {
                throw diagnostic()
            }
            return result
        }
        var base = try target(RuneGLPassRGBA16F)
        defer { rune_gl_pass_delete_target(pass, &base) }
        var lit = try target(RuneGLPassRGBA8)
        defer { rune_gl_pass_delete_target(pass, &lit) }

        let spec = AppSpec(size: Vec2(Float(size), Float(size)), state: ()) { _, _ in
            el().sizeFull().bg(Color(r: 0, g: 0, b: 0, a: 1))
        }
        let config = EmbedHostConfig(initialSize: spec.size)
        #if canImport(Metal) && canImport(QuartzCore)
        let host = try LayerHost(spec: spec, scale: 1, config: config)
        #else
        let host = LayerHost(spec: spec, scale: 1, config: config)
        #endif

        let startRune = clock.now
        let rune = try OpenGLLayerRenderer(resolve: resolve, isGLES: OffscreenGLContext.isGLES)
        defer { rune.close() }
        rune_gl_pass_bind_target(pass, base)
        _ = try rune.draw(host, at: 0)
        let runeMs = elapsedMs(startRune)

        let startFX = clock.now
        let fx = try FxGLRenderer(resolve: resolve)
        defer { fx.close() }
        try fx.warmAll()
        fx.setFireSim(true)
        // The solver compiles its six fragment programs on the first simulated fire draw.
        let fire = Fx.fire(FireParams(height: 16, embers: 0))
            .on(.rounded(x: 16, y: 32, w: 32, h: 16, radius: 4)).at(0.05)
        let viewport = SIMD2<UInt32>(UInt32(size), UInt32(size))
        let graph = fx.prepare(viewport: viewport, layers: [fire])
        try fx.encode(graph: graph, viewport: viewport, framebuffer: lit.framebuffer)
        let fxMs = elapsedMs(startFX)

        let startLight = clock.now
        let light = try LightGLRenderer(resolve: resolve)
        defer { light.close() }
        let lightMs = elapsedMs(startLight)

        let startGlass = clock.now
        let glass = try GlassGLRenderer(resolve: resolve)
        defer { glass.close() }
        let glassMs = elapsedMs(startGlass)

        if let snapPath {
            let scene = LightScene(
                prims: [Prim.rect(16, 16, 32, 32).radius(6).raised(4).albedo(SIMD3(0.3, 0.4, 0.6))],
                lights: [Light.point(32, 32, 48).color(SIMD3(1.0, 0.9, 0.8)).intensity(3)],
                settings: LightSettings(gi: GIParams())
            )
            try light.render(scene: scene, width: size, height: size, baseTexture: base.texture,
                             textTexture: 0, framebuffer: lit.framebuffer)
            let snap = try context.withFramebuffer(width: size, height: size) {
                try glass.render(glass: [.rounded(12, 12, 40, 40, radius: 8)], width: size, height: size,
                                 backdrop: lit.texture, fluence: light.fluenceTexture)
            }
            let url = URL(fileURLWithPath: snapPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snap.writePNG(to: url)
        }
        report(deviceMs, runeMs, fxMs, lightMs, glassMs)
    }
}
#endif
