import Foundation
import Rune
import RuneFX
import RuneLight
import RuneRef

#if canImport(Metal)
import Metal
#endif

/// Port of `crates/rune-light/examples/shader_first_use.rs`.
///
/// Times first-use shader & pipeline compilation for `MetalRenderer` (`Rune`),
/// `FxRenderer` (`RuneFX`), `LightRenderer` (`RuneLight`), and `GlassRenderer` (`RuneLight`).
/// Prints one JSON line in milliseconds, and supports `--snap PATH` for smoke checks.
@main
enum RuneLightShaderFirstUseApp {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let snapPath: String? = {
            guard let i = args.firstIndex(of: "--snap"), i + 1 < args.count else { return nil }
            return args[i + 1]
        }()

        #if canImport(Metal)
        let clock = ContinuousClock()
        func elapsedMs(since t0: ContinuousClock.Instant) -> Double {
            let d = clock.now - t0
            return Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) * 1e-15
        }

        let tDev = clock.now
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fputs("error: Metal device unavailable\n", stderr)
            Foundation.exit(1)
        }
        let deviceMs = elapsedMs(since: tDev)

        let tRune = clock.now
        let renderer = try MetalRenderer(device: device)
        _ = renderer.hasCompiledExtendedShaders
        let runeMs = elapsedMs(since: tRune)

        let tFx = clock.now
        let fx = try FxRenderer(device: device, pixelFormat: .bgra8Unorm_srgb, options: FxOptions())
        fx.addFormat(.rgba16Float)
        try fx.warmAll()
        let fxMs = elapsedMs(since: tFx)

        let tLight = clock.now
        let light = try LightRenderer(device: device, width: 64, height: 64, outputFormat: .rgba8Unorm)
        let lightMs = elapsedMs(since: tLight)

        let tGlass = clock.now
        let glass = try GlassRenderer(device: device, pixelFormat: .rgba8Unorm)
        let glassMs = elapsedMs(since: tGlass)

        if let snapPath {
            func tex(_ fmt: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: 64, height: 64, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .shared
                return device.makeTexture(descriptor: d)
            }
            if let base = tex(.rgba16Float), let text = tex(.rgba16Float),
               let lit = tex(.rgba8Unorm), let out = tex(.rgba8Unorm),
               let cmd = queue.makeCommandBuffer() {
                let scene = LightScene(
                    prims: [Prim.rect(16, 16, 32, 32).radius(6).raised(4).albedo(SIMD3<Float>(0.3, 0.4, 0.6))],
                    lights: [Light.point(32, 32, 48).color(SIMD3<Float>(1.0, 0.9, 0.8)).intensity(3.0)],
                    settings: LightSettings(gi: GIParams())
                )
                _ = light.render(scene: scene, commandBuffer: cmd, baseTexture: base, textTexture: text, targetTexture: lit)
                try glass.render(
                    commandBuffer: cmd,
                    glass: [Glass.rounded(12, 12, 40, 40, radius: 8)],
                    lights: [],
                    settings: GlassSettings(),
                    backdrop: lit,
                    fluence: light.inspect().fluence,
                    target: out
                )
                cmd.commit()
                cmd.waitUntilCompleted()
                var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
                out.getBytes(&rgba, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
                let url = URL(fileURLWithPath: snapPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Frame(width: 64, height: 64, rgba: rgba).writePNG(to: url)
            }
        }

        print(String(
            format: "{\"device\":%.3f,\"rune\":%.3f,\"fx\":%.3f,\"light\":%.3f,\"glass\":%.3f}",
            deviceMs, runeMs, fxMs, lightMs, glassMs
        ))
        #else
        fputs("error: Metal unavailable on this platform\n", stderr)
        Foundation.exit(1)
        #endif
    }
}
