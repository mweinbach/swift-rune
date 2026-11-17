import Foundation
import Rune
import RuneLight
import RuneRef

#if canImport(Metal)
import Metal
#endif

struct DemoVisibility {
    let width: Int
    let height: Int
    let sample: (Int, Int) -> Float
}

protocol LightDemoContext {
    var ts: TextSystem { get }
    func enableTimings()
    var gpuMilliseconds: Double? { get }
    func visibility() throws -> DemoVisibility
    func drawUI(base: [DemoUIInst], text: [DemoUIInst], clear: Color) throws
    func lightFrame(prims: [Prim], lights: [Light], settings: LightSettings, read: Bool) throws -> [UInt8]?
}

#if canImport(Metal)
private final class DemoCtx: LightDemoContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let ui: DemoUIRenderer
    let ts: TextSystem
    let light: LightRenderer
    let baseTex: MTLTexture
    let textTex: MTLTexture
    let outTex: MTLTexture
    private var timingEnabled = false
    private(set) var gpuMilliseconds: Double?
    func enableTimings() { timingEnabled = true }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RuneLightDemos", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
        }
        self.device = device
        self.queue = queue
        self.ui = try DemoUIRenderer(device: device, pixelFormat: .rgba16Float)
        self.ts = TextSystem()
        self.light = try LightRenderer(device: device, width: UInt32(demoW), height: UInt32(demoH), outputFormat: .rgba8Unorm)

        func makeTex(_ fmt: MTLPixelFormat, storage: MTLStorageMode) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: demoW, height: demoH, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = storage
            return device.makeTexture(descriptor: d)!
        }
        self.baseTex = makeTex(.rgba16Float, storage: .private)
        self.textTex = makeTex(.rgba16Float, storage: .private)
        self.outTex = makeTex(.rgba8Unorm, storage: .shared)
    }

    func drawUI(base: [DemoUIInst], text: [DemoUIInst], clear: Color) {
        let cmd = queue.makeCommandBuffer()!
        ui.draw(
            commandBuffer: cmd,
            target: baseTex,
            clear: MTLClearColor(red: Double(clear.r), green: Double(clear.g), blue: Double(clear.b), alpha: 1.0),
            insts: base,
            glyphAtlas: ts.glyphAtlas
        )
        ui.draw(
            commandBuffer: cmd,
            target: textTex,
            clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
            insts: text,
            glyphAtlas: ts.glyphAtlas
        )
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    func visibility() -> DemoVisibility {
        let (fw, fh) = light.fieldSize
        let stDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: light.visibilityTexture.pixelFormat,
            width: Int(fw),
            height: Int(fh),
            mipmapped: false
        )
        stDesc.usage = .shaderRead
        stDesc.storageMode = .shared
        let visStaging = device.makeTexture(descriptor: stDesc)!
        let blitCmd = queue.makeCommandBuffer()!
        let blit = blitCmd.makeBlitCommandEncoder()!
        blit.copy(
            from: light.visibilityTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: Int(fw), height: Int(fh), depth: 1),
            to: visStaging,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        blitCmd.commit()
        blitCmd.waitUntilCompleted()

        var vis = [Float16](repeating: Float16(0), count: Int(fw * fh) * 4)
        vis.withUnsafeMutableBytes { raw in
            visStaging.getBytes(
                raw.baseAddress!,
                bytesPerRow: Int(fw) * 8,
                from: MTLRegionMake2D(0, 0, Int(fw), Int(fh)),
                mipmapLevel: 0
            )
        }

        return DemoVisibility(width: Int(fw), height: Int(fh)) { x, y in
            Float(vis[(y * Int(fw) + x) * 4])
        }
    }

    func lightFrame(prims: [Prim], lights: [Light], settings: LightSettings, read: Bool) -> [UInt8]? {
        let cmd = queue.makeCommandBuffer()!
        let scene = LightScene(prims: prims, lights: lights, settings: settings, emission: nil)
        _ = light.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: outTex)
        cmd.commit()
        cmd.waitUntilCompleted()
        if timingEnabled { gpuMilliseconds = light.readTimings(commandBuffer: cmd)?.total }
        guard read else { return nil }
        var rgba = [UInt8](repeating: 0, count: demoW * demoH * 4)
        outTex.getBytes(&rgba, bytesPerRow: demoW * 4, from: MTLRegionMake2D(0, 0, demoW, demoH), mipmapLevel: 0)
        return rgba
    }
}

#endif

private func downscale(_ src: [UInt8], w: Int, h: Int, factor k: Int) -> [UInt8] {
    let ow = w / k
    let oh = h / k
    var out = [UInt8](repeating: 0, count: ow * oh * 4)
    let inv = 1.0 / Float(k * k)
    for y in 0..<oh {
        for x in 0..<ow {
            var acc = SIMD3<Float>.zero
            for dy in 0..<k {
                for dx in 0..<k {
                    let i = ((y * k + dy) * w + x * k + dx) * 4
                    acc.x += RefShader.srgbToLinear(Float(src[i]) / 255.0)
                    acc.y += RefShader.srgbToLinear(Float(src[i + 1]) / 255.0)
                    acc.z += RefShader.srgbToLinear(Float(src[i + 2]) / 255.0)
                }
            }
            let o = (y * ow + x) * 4
            out[o] = UInt8((RefShader.linearToSRGB(acc.x * inv) * 255.0).rounded())
            out[o + 1] = UInt8((RefShader.linearToSRGB(acc.y * inv) * 255.0).rounded())
            out[o + 2] = UInt8((RefShader.linearToSRGB(acc.z * inv) * 255.0).rounded())
            out[o + 3] = 255
        }
    }
    return out
}

private func renderDemo(ctx: any LightDemoContext, demo: any LightDemo, out: URL, frames: Int?) throws {
    let name = demo.name
    let stillFrame = Int((demo.still * Float(demoFPS)).rounded())
    if frames == 0 {
        let t = Float(stillFrame) / Float(demoFPS)
        var f = demo.frame(ts: ctx.ts, t: t, scale: 2.0)
        f.settings.seed = 0
        try ctx.drawUI(base: f.base, text: f.text, clear: f.clear)
        if let px = try ctx.lightFrame(prims: f.prims, lights: f.lights, settings: f.settings, read: true) {
            try Frame(width: demoW, height: demoH, rgba: px).writePNG(to: out.appendingPathComponent("\(name).png"))
        }
        return
    }

    let n = frames ?? Int((demo.seconds * Float(demoFPS)).rounded())
    let stripAt = (0..<5).map { ($0 * n) / 5 + n / 10 }
    var strip: [[UInt8]] = []

    let movie: ToolingVideoEncoder?
    do {
        movie = try ToolingVideoEncoder(outputPath: out.appendingPathComponent("\(name).mp4").path,
                                       width: demoW, height: demoH, fps: Double(demoFPS))
    } catch ToolingError.ffmpegUnavailable {
        movie = nil
    }

    for fIdx in 0..<n {
        let t = Float(fIdx) / Float(demoFPS)
        var f = demo.frame(ts: ctx.ts, t: t, scale: 2.0)
        f.settings.seed = 0
        try ctx.drawUI(base: f.base, text: f.text, clear: f.clear)
        if let px = try ctx.lightFrame(prims: f.prims, lights: f.lights, settings: f.settings, read: true) {
            if fIdx == stillFrame {
                try Frame(width: demoW, height: demoH, rgba: px).writePNG(to: out.appendingPathComponent("\(name).png"))
            }
            if stripAt.contains(fIdx) {
                strip.append(downscale(px, w: demoW, h: demoH, factor: 4))
            }
            try movie?.writeFrame(Frame(width: demoW, height: demoH, rgba: px))
        }
    }
    try movie?.finish()
    if !strip.isEmpty {
        let sw = demoW / 4
        let sh = demoH / 4
        let gap = 8
        let tw = sw * strip.count + gap * max(0, strip.count - 1)
        var img = [UInt8](repeating: 12, count: tw * sh * 4)
        for (k, fr) in strip.enumerated() {
            let ox = k * (sw + gap)
            for y in 0..<sh {
                let src = fr[(y * sw * 4)..<((y + 1) * sw * 4)]
                let d = (y * tw + ox) * 4
                img.replaceSubrange(d..<(d + src.count), with: src)
            }
        }
        for i in stride(from: 3, to: img.count, by: 4) { img[i] = 255 }
        try Frame(width: tw, height: sh, rgba: img).writePNG(to: out.appendingPathComponent("\(name)-strip.png"))
    }
}

private func median(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s[s.count / 2]
}

private func runBench(ctx: any LightDemoContext, out: URL, frames: Int?) throws {
    let frameCount = frames ?? 90
    guard frameCount > 0 else { throw ToolingError.invalidArgument("bench needs at least one frame") }
    let warmup = frameCount / 3
    ctx.enableTimings()
    let ui = DemoUIBuilder(ts: ctx.ts, clear: oklch(0.17, 0.006, 265), scale: 2.0)
    let card = oklch(0.235, 0.007, 265)
    for i in 0..<10 {
        for j in 0..<10 {
            let x = 30 + Float(j) * 124
            let y = 20 + Float(i) * 78
            ui.rect(x, y, 104 + Float((i * 7) % 13), 56, radius: 14, fill: card) {
                $0.raised(7 * 2).bevel(width: 6 * 2, height: 2 * 2).gloss(0.5, roughness: 0.4)
            }
            ui.text(x + 12, y + 18, "Message", size: 13, weight: 400, color: oklch(0.9, 0, 0))
        }
    }
    try ctx.drawUI(base: ui.base, text: ui.text, clear: ui.clear)

    let cfgs: [(String, Int, Bool, Bool)] = [
        ("1 light", 1, false, false),
        ("4 lights", 4, false, false),
        ("8 lights", 8, false, false),
        ("4 lights + shafts", 4, true, false),
        ("GI only (emitters)", 0, false, true),
        ("4 lights + GI bounce", 4, false, true),
    ]
    var report = "{\n"
    let clock = ContinuousClock()
    for (ci, (label, nl, shafts, gi)) in cfgs.enumerated() {
        var gpuTimes: [Double] = []
        var wallTimes: [Double] = []
        for f in 0..<frameCount {
            let t = Float(f) / 60.0
            let lights: [Light] = (0..<nl).map { k in
                let a = t * 0.8 + Float(k) * 1.7
                let l = Light.point((640 + 420 * cosf(a)) * 2, (400 + 260 * sinf(a)) * 2, 60 * 2)
                    .intensity(1.5).radius(10 * 2).range(1200 * 2)
                return shafts ? l.shafts(0.4) : l
            }
            var p = ui.prims
            if gi {
                for k in p.indices where k % 9 == 0 {
                    p[k] = p[k].emissive(SIMD3<Float>(2.0, 0.6, 0.3))
                }
            }
            let s = LightSettings(gi: gi ? GIParams(bounce: nl > 0 ? 0.25 : 0.0) : nil)
            let start = clock.now
            _ = try ctx.lightFrame(prims: p, lights: lights, settings: s, read: false)
            let elapsed = (clock.now - start).components
            let gpuTime = ctx.gpuMilliseconds
            if f >= warmup {
                wallTimes.append(Double(elapsed.seconds) * 1e3 + Double(elapsed.attoseconds) * 1e-15)
                if let gpuTime { gpuTimes.append(gpuTime) }
            }
        }
        let gpuTime = gpuTimes.isEmpty ? nil : median(gpuTimes)
        let wall = median(wallTimes)
        let gpuReport = gpuTime.map { String(format: "%.3f ms (GPU timestamps)", $0) } ?? "GPU timestamps unavailable"
        let padLabel = String(repeating: " ", count: max(0, 24 - label.count)) + label
        print(String(format: "%@: %@   whole frame %.3f ms (wall, GPU complete)  (%d prims)", padLabel, gpuReport, wall, ui.prims.count))
        let gpuJSON = gpuTime.map { String(format: "%.4f", $0) } ?? "null"
        report += String(format: "  \"%@\": {\"total\": %@, \"frame_wall\": %.4f}%@\n", label, gpuJSON, wall, ci + 1 < cfgs.count ? "," : "")
    }
    report += "}\n"
    try report.write(to: out.appendingPathComponent("bench.json"), atomically: true, encoding: .utf8)
}

private func runVerify(ctx: any LightDemoContext) throws {
    let prims: [Prim] = [
        Prim.rect(600, 500, 400, 200).radius(28).raised(14),
        Prim.rect(1200, 650, 300, 300).radius(60).raised(24),
        Prim.rect(1500, 300, 360, 160).radius(20).floating(bottom: 40, top: 48),
    ]
    let light = Light.point(400, 420, 120).intensity(1.5).radius(24).range(6000)
    let ui = DemoUIBuilder(ts: ctx.ts, clear: oklch(0.2, 0, 0), scale: 2.0)
    try ctx.drawUI(base: ui.base, text: ui.text, clear: ui.clear)
    _ = try ctx.lightFrame(prims: prims, lights: [light], settings: LightSettings(), read: false)

    let visibility = try ctx.visibility()
    func topZ(_ p: SIMD2<Float>) -> Float {
        for pr in prims.reversed() {
            if RuneLightCPU.field(prims: [pr.raised(1).floating(bottom: pr.z.x, top: pr.z.y)], at: p).x < 0 {
                return pr.z.y
            }
        }
        return 0
    }

    var maxEst: Float = 0
    var sumEst: Float = 0
    var nAll: Int = 0
    var sumPen: Float = 0
    var maxPen: Float = 0
    var nPen: Int = 0
    var rows: [String] = []
    var worst = ""

    for gy in 0..<40 {
        for gx in 0..<64 {
            let x = gx * visibility.width / 64 + 3
            let y = gy * visibility.height / 40 + 5
            let pxy = SIMD2<Float>((Float(x) + 0.5) * 2.0, (Float(y) + 0.5) * 2.0)
            let z = topZ(pxy)
            if prims.contains(where: { abs(RuneLightCPU.field(prims: [$0], at: pxy).x) < 3.0 }) {
                continue
            }
            let p = SIMD3<Float>(pxy.x, pxy.y, z + 0.35)
            let g = visibility.sample(x, y)
            let e = RuneLightCPU.estimate(prims: prims, light: light, at: p)
            if abs(g - e) > maxEst {
                worst = String(format: "worst texel (%d,%d) z %.1f: gpu %.3f vs cpu %.3f", x, y, z, g, e)
            }
            maxEst = max(maxEst, abs(g - e))
            sumEst += abs(g - e)
            nAll += 1
            let gt = RuneLightCPU.groundTruth(prims: prims, light: light, at: p, samples: 20)
            if gt > 0.02 && gt < 0.98 {
                sumPen += abs(g - gt)
                maxPen = max(maxPen, abs(g - gt))
                nPen += 1
                if rows.count < 12 {
                    rows.append(String(format: "  (%4d,%4d) z %4.1f  gpu %.3f  cpu-est %.3f  ground-truth %.3f", x, y, z, g, e, gt))
                }
            }
        }
    }

    for r in rows { print(r) }
    print(worst)
    print(String(
        format: "%d texels: max |gpu - cpu estimator| = %.4f, mean %.5f; %d penumbra texels: mean |gpu - ground truth| = %.3f, max %.3f",
        nAll, maxEst, sumEst / Float(max(nAll, 1)), nPen, sumPen / Float(max(nPen, 1)), maxPen
    ))
}

@main
enum RuneLightDemosApp {
    static func main() throws {
        try run(args: Array(CommandLine.arguments.dropFirst()))
    }

    static func run(args: [String]) throws {
        func arg(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let snapPath = arg("--snap")
        let out = URL(fileURLWithPath: arg("--out") ?? "demo/light", isDirectory: true)
        let frames: Int?
        if args.contains("--frames") {
            guard let count = arg("--frames").flatMap(Int.init), count >= 0 else {
                throw ToolingError.invalidArgument("--frames needs a nonnegative integer")
            }
            frames = count
        } else {
            frames = nil
        }
        var cmd = "all"
        var arguments = args.makeIterator()
        command: while let argument = arguments.next() {
            switch argument {
            case "--out", "--scene", "--frames", "--snap", "--t":
                _ = arguments.next()
            default:
                if !argument.hasPrefix("-") {
                    cmd = argument
                    break command
                }
            }
        }

        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        let ctx: any LightDemoContext
        #if canImport(Metal) && canImport(CRuneOffscreenGL)
        if args.contains("--gl") {
            ctx = try DemoGLContext()
        } else {
            ctx = try DemoCtx()
        }
        #elseif canImport(Metal)
        ctx = try DemoCtx()
        #else
        ctx = try DemoGLContext()
        #endif
        let demos = makeAllDemos()

        if let snapPath {
            let sceneName = arg("--scene") ?? "chat"
            guard let demo = demos.first(where: { $0.name == sceneName }) else {
                throw LightRendererError.shaderCompileFailed("Unknown scene '\(sceneName)'")
            }
            let t = arg("--t").flatMap(Float.init) ?? demo.still
            var f = demo.frame(ts: ctx.ts, t: t, scale: 2.0)
            f.settings.seed = 0
            try ctx.drawUI(base: f.base, text: f.text, clear: f.clear)
            if let px = try ctx.lightFrame(prims: f.prims, lights: f.lights, settings: f.settings, read: true) {
                let url = URL(fileURLWithPath: snapPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Frame(width: demoW, height: demoH, rgba: px).writePNG(to: url)
            }
            return
        }

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        switch cmd {
        case "bench":
            try runBench(ctx: ctx, out: out, frames: frames)
        case "verify":
            try runVerify(ctx: ctx)
        case "all":
            for d in demos {
                try renderDemo(ctx: ctx, demo: d, out: out, frames: frames)
            }
        default:
            guard let d = demos.first(where: { $0.name == cmd }) else {
                throw LightRendererError.shaderCompileFailed("Unknown demo '\(cmd)'")
            }
            try renderDemo(ctx: ctx, demo: d, out: out, frames: frames)
        }
        #else
        throw LightRendererError.shaderCompileFailed("No desktop GL or Metal renderer for this platform")
        #endif
    }
}
