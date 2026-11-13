import Foundation
import RuneFX
import RuneLight
import RuneRef

#if canImport(Metal)
import Metal
#endif

/// Port of `crates/rune-light/examples/frame_bench.rs`.
///
/// CPU command-buffer recording benchmark for `LightRenderer`, `GlassRenderer`, and `FxRenderer` at 2560x1600.
/// Prints median microseconds per stage; supports `--fast` (smaller sample count) and `--snap PATH`.
@main
enum RuneLightFrameBenchApp {
    static func main() throws {
        try run(args: Array(CommandLine.arguments.dropFirst()))
    }

    static func run(args: [String]) throws {
        let fast = args.contains("--fast")
        let snapPath: String? = {
            guard let i = args.firstIndex(of: "--snap"), i + 1 < args.count else { return nil }
            return args[i + 1]
        }()

        #if canImport(Metal)
        let w: Int = 2560
        let h: Int = 1600
        let format: MTLPixelFormat = .rgba8Unorm
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fputs("error: Metal device unavailable\n", stderr)
            Foundation.exit(1)
        }

        func makeTex(_ fmt: MTLPixelFormat) -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            return device.makeTexture(descriptor: desc)!
        }

        let base = makeTex(.rgba16Float)
        let text = makeTex(.rgba16Float)
        let target = makeTex(format)
        let out = makeTex(format)

        let lights = [
            Light.point(400, 300, 200),
            Light.point(1800, 900, 160),
        ]
        func makePrims(_ n: Int) -> [Prim] {
            (0..<n).map { i in
                Prim.rect(Float(i % 20) * 120, Float(i / 20) * 60, 100, 44).radius(10).raised(6)
            }
        }
        let small = makePrims(16)
        let big = makePrims(300)
        func scene(_ prims: [Prim], gi: GIParams?) -> LightScene {
            LightScene(prims: prims, lights: lights, settings: LightSettings(gi: gi))
        }
        func finish(_ cmd: MTLCommandBuffer) {
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        let clock = ContinuousClock()
        func us(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) * 1e-12
        }
        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        let growSamples = fast ? 3 : 30
        var grow: [Double] = []
        grow.reserveCapacity(growSamples)
        for _ in 0..<growSamples {
            let l = try LightRenderer(device: device, width: UInt32(w), height: UInt32(h), outputFormat: format)
            if let cmd0 = queue.makeCommandBuffer() {
                _ = l.render(scene: scene(small, gi: nil), commandBuffer: cmd0, baseTexture: base, textTexture: text, targetTexture: target)
                finish(cmd0)
            }
            if let cmd1 = queue.makeCommandBuffer() {
                let t0 = clock.now
                _ = l.render(scene: scene(big, gi: nil), commandBuffer: cmd1, baseTexture: base, textTexture: text, targetTexture: target)
                grow.append(us(clock.now - t0))
                finish(cmd1)
            }
        }
        print(String(format: "grow past 256 prims  %8.1f us", median(grow)))

        let light = try LightRenderer(device: device, width: UInt32(w), height: UInt32(h), outputFormat: format)
        if let cmd = queue.makeCommandBuffer() {
            _ = light.render(scene: scene(small, gi: nil), commandBuffer: cmd, baseTexture: base, textTexture: text, targetTexture: target)
            finish(cmd)
        }
        print(String(format: "gi off textures      %8d", light.giSize.0 > 0 ? 5 : 0))

        let glass = try GlassRenderer(device: device, pixelFormat: format)
        let panes = [
            Glass.rounded(200, 200, 600, 400, radius: 40),
            Glass.rounded(1200, 600, 500, 300, radius: 30),
        ]

        let warmup = fast ? 4 : 20
        let totalFrames = fast ? 16 : 320
        for (name, gi) in [("light steady gi off", Optional<GIParams>.none), ("light steady gi on", Optional(GIParams()))] {
            var lTimes: [Double] = []
            var gTimes: [Double] = []
            for frame in 0..<totalFrames {
                if let cmd = queue.makeCommandBuffer() {
                    let t0 = clock.now
                    _ = light.render(scene: scene(small, gi: gi), commandBuffer: cmd, baseTexture: base, textTexture: text, targetTexture: target)
                    let litUs = us(clock.now - t0)
                    let fluence = light.inspect().fluence
                    let t1 = clock.now
                    try glass.render(
                        commandBuffer: cmd,
                        glass: panes,
                        lights: [],
                        settings: GlassSettings(),
                        backdrop: target,
                        fluence: fluence,
                        target: out
                    )
                    let glassUs = us(clock.now - t1)
                    finish(cmd)
                    if frame >= warmup {
                        lTimes.append(litUs)
                        gTimes.append(glassUs)
                    }
                }
            }
            print(String(format: "%-20@ %8.1f us", (name as NSString), median(lTimes)))
            print(String(format: "glass steady (%@)  %8.1f us", ((gi != nil ? "gi on " : "gi off") as NSString), median(gTimes)))
        }

        let fx = try FxRenderer(device: device, pixelFormat: format, options: FxOptions())
        let layers: [FxLayer] = (0..<16).map { i in
            let shape = FxShape.rounded(
                x: 100 + Float(i % 4) * 300,
                y: 100 + Float(i / 4) * 200,
                w: 200,
                h: 120,
                radius: 20
            )
            let effect: Fx = (i % 4 == 0)
                ? .lens(LensParams(frost: 0.6))
                : .glow(GlowParams(radius: 12, intensity: 0.8))
            return effect.on(shape).at(0.5)
        }

        var fTimes: [Double] = []
        for frame in 0..<totalFrames {
            if let cmd = queue.makeCommandBuffer() {
                let t0 = clock.now
                _ = fx.prepare(
                    frame: FxFrame(
                        viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)),
                        scale: 1.0,
                        layers: layers,
                        backdrop: base,
                        sources: []
                    )
                )
                for i in stride(from: 0, to: layers.count, by: 4) {
                    _ = try fx.blurBackdrop(commandBuffer: cmd, backdrop: base, layer: i)
                }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .load
                pass.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                    try fx.drawAll(encoder: enc, layers: layers, place: nil)
                    enc.endEncoding()
                }
                let usVal = us(clock.now - t0)
                finish(cmd)
                if frame >= warmup {
                    fTimes.append(usVal)
                }
            }
        }
        print(String(format: "fx steady 16 layers  %8.1f us", median(fTimes)))

        if let snapPath {
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            out.getBytes(&rgba, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let url = URL(fileURLWithPath: snapPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Frame(width: w, height: h, rgba: rgba).writePNG(to: url)
        }
        #else
        fputs("error: Metal unavailable on this platform\n", stderr)
        Foundation.exit(1)
        #endif
    }
}
