import Foundation
import Rune
import RuneLight
import RuneRef

#if canImport(Metal)
import Metal
#endif

#if canImport(Metal)
private final class DemoCtx {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let ui: DemoUIRenderer
    let ts: TextSystem
    let light: LightRenderer
    let baseTex: MTLTexture
    let textTex: MTLTexture
    let outTex: MTLTexture

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

    func lightFrame(prims: [Prim], lights: [Light], settings: LightSettings, read: Bool) -> [UInt8]? {
        let cmd = queue.makeCommandBuffer()!
        let scene = LightScene(prims: prims, lights: lights, settings: settings, emission: nil)
        _ = light.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: outTex)
        cmd.commit()
        cmd.waitUntilCompleted()
        guard read else { return nil }
        var rgba = [UInt8](repeating: 0, count: demoW * demoH * 4)
        outTex.getBytes(&rgba, bytesPerRow: demoW * 4, from: MTLRegionMake2D(0, 0, demoW, demoH), mipmapLevel: 0)
        return rgba
    }
}

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

private func renderDemo(ctx: DemoCtx, demo: any LightDemo, out: URL, frames: Int?) throws {
    let name = demo.name
    let stillFrame = Int((demo.still * Float(demoFPS)).rounded())
    if frames == 0 {
        let t = Float(stillFrame) / Float(demoFPS)
        var f = demo.frame(ts: ctx.ts, t: t, scale: 2.0)
        f.settings.seed = 0
        ctx.drawUI(base: f.base, text: f.text, clear: f.clear)
        if let px = ctx.lightFrame(prims: f.prims, lights: f.lights, settings: f.settings, read: true) {
            try Frame(width: demoW, height: demoH, rgba: px).writePNG(to: out.appendingPathComponent("\(name).png"))
        }
        return
    }

    let n = frames ?? Int((demo.seconds * Float(demoFPS)).rounded())
    let stripAt = (0..<5).map { ($0 * n) / 5 + n / 10 }
    var strip: [[UInt8]] = []

#if os(macOS)
    let mp4 = out.appendingPathComponent("\(name).mp4")
    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ff.arguments = [
        "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba",
        "-s", "\(demoW)x\(demoH)", "-framerate", "\(demoFPS)", "-i", "-",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv", "-c:v", "libx264",
        "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-movflags", "+faststart", mp4.path,
    ]
    let pipe = Pipe()
    ff.standardInput = pipe
    let canEncodeMP4 = (try? ff.run()) != nil
#endif

    for fIdx in 0..<n {
        let t = Float(fIdx) / Float(demoFPS)
        var f = demo.frame(ts: ctx.ts, t: t, scale: 2.0)
        f.settings.seed = 0
        ctx.drawUI(base: f.base, text: f.text, clear: f.clear)
        if let px = ctx.lightFrame(prims: f.prims, lights: f.lights, settings: f.settings, read: true) {
            if fIdx == stillFrame {
                try Frame(width: demoW, height: demoH, rgba: px).writePNG(to: out.appendingPathComponent("\(name).png"))
            }
            if stripAt.contains(fIdx) {
                strip.append(downscale(px, w: demoW, h: demoH, factor: 4))
            }
#if os(macOS)
            if canEncodeMP4 {
                try? pipe.fileHandleForWriting.write(contentsOf: Data(px))
            }
#endif
        }
    }
#if os(macOS)
    if canEncodeMP4 {
        try? pipe.fileHandleForWriting.close()
        ff.waitUntilExit()
    }
#endif
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

private func runBench(ctx: DemoCtx, out: URL) throws {
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
    ctx.drawUI(base: ui.base, text: ui.text, clear: ui.clear)

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
        var totals: [Double] = []
        for f in 0..<90 {
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
            let cmd = ctx.queue.makeCommandBuffer()!
            _ = ctx.light.render(scene: LightScene(prims: p, lights: lights, settings: s), commandBuffer: cmd, baseTexture: ctx.baseTex, textTexture: ctx.textTex, targetTexture: ctx.outTex)
            cmd.commit()
            cmd.waitUntilCompleted()
            if f >= 30, let tm = ctx.light.readTimings(commandBuffer: cmd) {
                totals.append(tm.total)
            }
        }
        let t0 = clock.now
        for _ in 0..<120 {
            _ = ctx.lightFrame(prims: ui.prims, lights: [], settings: LightSettings(), read: false)
        }
        let d = clock.now - t0
        let wall = (Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) * 1e-15) / 120.0
        let tot = median(totals)
        let padLabel = String(repeating: " ", count: max(0, 24 - label.count)) + label
        print(String(format: "%@: total %.3f ms (timestamps)   whole frame %.3f ms (wall)  (%d prims)", padLabel, tot, wall, ui.prims.count))
        report += String(format: "  \"%@\": {\"total\": %.4f, \"frame_wall\": %.4f}%@\n", label, tot, wall, ci + 1 < cfgs.count ? "," : "")
    }
    report += "}\n"
    try report.write(to: out.appendingPathComponent("bench.json"), atomically: true, encoding: .utf8)
}

private func runVerify(ctx: DemoCtx) {
    let prims: [Prim] = [
        Prim.rect(600, 500, 400, 200).radius(28).raised(14),
        Prim.rect(1200, 650, 300, 300).radius(60).raised(24),
        Prim.rect(1500, 300, 360, 160).radius(20).floating(bottom: 40, top: 48),
    ]
    let light = Light.point(400, 420, 120).intensity(1.5).radius(24).range(6000)
    let ui = DemoUIBuilder(ts: ctx.ts, clear: oklch(0.2, 0, 0), scale: 2.0)
    ctx.drawUI(base: ui.base, text: ui.text, clear: ui.clear)
    _ = ctx.lightFrame(prims: prims, lights: [light], settings: LightSettings(), read: false)

    let (fw, fh) = ctx.light.fieldSize
    let stDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: ctx.light.visibilityTexture.pixelFormat,
        width: Int(fw),
        height: Int(fh),
        mipmapped: false
    )
    stDesc.usage = .shaderRead
    stDesc.storageMode = .shared
    let visStaging = ctx.device.makeTexture(descriptor: stDesc)!
    let blitCmd = ctx.queue.makeCommandBuffer()!
    let blit = blitCmd.makeBlitCommandEncoder()!
    blit.copy(
        from: ctx.light.visibilityTexture,
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

    func gpuVis(_ x: Int, _ y: Int) -> Float {
        Float(vis[(y * Int(fw) + x) * 4])
    }
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
            let x = gx * Int(fw) / 64 + 3
            let y = gy * Int(fh) / 40 + 5
            let pxy = SIMD2<Float>((Float(x) + 0.5) * 2.0, (Float(y) + 0.5) * 2.0)
            let z = topZ(pxy)
            if prims.contains(where: { abs(RuneLightCPU.field(prims: [$0], at: pxy).x) < 3.0 }) {
                continue
            }
            let p = SIMD3<Float>(pxy.x, pxy.y, z + 0.35)
            let g = gpuVis(x, y)
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
#endif

@main
enum RuneLightDemosApp {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func arg(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let snapPath = arg("--snap")
        let out = URL(fileURLWithPath: arg("--out") ?? "demo/light", isDirectory: true)
        let frames = arg("--frames").flatMap(Int.init)
        let cmd = (args.first?.hasPrefix("--") == false) ? args.first! : "all"

        #if canImport(Metal)
        let ctx = try DemoCtx()
        let demos = makeAllDemos()

        if let snapPath {
            let sceneName = arg("--scene") ?? "chat"
            guard let demo = demos.first(where: { $0.name == sceneName }) else {
                fputs("error: unknown scene '\(sceneName)'\n", stderr)
                Foundation.exit(1)
            }
            let t = arg("--t").flatMap(Float.init) ?? demo.still
            var f = demo.frame(ts: ctx.ts, t: t, scale: 2.0)
            f.settings.seed = 0
            ctx.drawUI(base: f.base, text: f.text, clear: f.clear)
            if let px = ctx.lightFrame(prims: f.prims, lights: f.lights, settings: f.settings, read: true) {
                let url = URL(fileURLWithPath: snapPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Frame(width: demoW, height: demoH, rgba: px).writePNG(to: url)
            }
            return
        }

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        switch cmd {
        case "bench":
            try runBench(ctx: ctx, out: out)
        case "verify":
            runVerify(ctx: ctx)
        case "all":
            for d in demos {
                try renderDemo(ctx: ctx, demo: d, out: out, frames: frames)
            }
        default:
            guard let d = demos.first(where: { $0.name == cmd }) else {
                fputs("error: unknown demo '\(cmd)'\n", stderr)
                Foundation.exit(1)
            }
            try renderDemo(ctx: ctx, demo: d, out: out, frames: frames)
        }
        #else
        fputs("error: Metal unavailable on this platform\n", stderr)
        Foundation.exit(1)
        #endif
    }
}
