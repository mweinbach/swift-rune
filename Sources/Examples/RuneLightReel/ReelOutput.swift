import Foundation
import RuneLight
import RuneRef

#if canImport(Metal)
import Metal
#endif

#if canImport(Metal)
func writeReelPNG(url: URL, width: Int, height: Int, rgba: [UInt8]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Frame(width: width, height: height, rgba: rgba).writePNG(to: url)
}

private func downscaleRGBA(_ src: [UInt8], width: Int, height: Int, factor: Int) -> [UInt8] {
    let ow = width / factor
    let oh = height / factor
    var out = [UInt8](repeating: 0, count: ow * oh * 4)
    for y in 0..<oh {
        for x in 0..<ow {
            var acc = SIMD3<Float>(0, 0, 0)
            for dy in 0..<factor {
                for dx in 0..<factor {
                    let i = ((y * factor + dy) * width + x * factor + dx) * 4
                    acc.x += RefShader.srgbToLinear(Float(src[i]) / 255.0)
                    acc.y += RefShader.srgbToLinear(Float(src[i + 1]) / 255.0)
                    acc.z += RefShader.srgbToLinear(Float(src[i + 2]) / 255.0)
                }
            }
            let o = (y * ow + x) * 4
            let inv = 1.0 / Float(factor * factor)
            out[o] = UInt8((RefShader.linearToSRGB(acc.x * inv) * 255.0).rounded())
            out[o + 1] = UInt8((RefShader.linearToSRGB(acc.y * inv) * 255.0).rounded())
            out[o + 2] = UInt8((RefShader.linearToSRGB(acc.z * inv) * 255.0).rounded())
            out[o + 3] = 255
        }
    }
    return out
}

#if os(macOS)
private func spawnFFmpeg(args: [String], output: URL) throws -> (Process, FileHandle) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo",
        "-s", "\(reelW)x\(reelH)", "-framerate", "\(reelFPS)",
    ] + args + [output.path]
    let pipe = Pipe()
    process.standardInput = pipe
    try process.run()
    return (process, pipe.fileHandleForWriting)
}
#endif

func runReelRender(reel: Reel, ctx: ReelCtx, outDir: URL, from: Float, to: Float) throws {
#if os(macOS)
    let tag = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv", "-movflags", "+faststart"]
    let h264Args = ["-pix_fmt", "yuv420p", "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-tune", "film", "-pix_fmt", "yuv420p"] + tag
    let hevcArgs = ["-pix_fmt", "yuv420p10le", "-i", "-", "-c:v", "libx265", "-preset", "medium", "-crf", "10", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-x265-params", "log-level=error:aq-mode=3"] + tag

    let (h264Proc, h264In) = try spawnFFmpeg(args: h264Args, output: outDir.appendingPathComponent("rc-reel.mp4"))
    let (hevcProc, hevcIn) = try spawnFFmpeg(args: hevcArgs, output: outDir.appendingPathComponent("rc-reel-master-10bit.mp4"))

    let n0 = Int((from * Float(reelFPS)).rounded())
    let n1 = Int((to * Float(reelFPS)).rounded())
    let posterT = reelTEnd + 1.8
    let sheetT: [Float] = [
        reelTTilt + 2.2, reelTInputs + 1.0, reelTCascades + 2.2,
        reelTMerge + 1.4, reelTFluence + 0.7, reelTUntilt + 0.9,
    ]
    var sheet: [[UInt8]] = []
    let t0 = DispatchTime.now().uptimeNanoseconds

    for f in n0..<n1 {
        let t = Float(f) / Float(reelFPS)
        let (view, _) = try reel.frame(ctx: ctx, t: t, bench: false)
        let wantPoster = abs(t - posterT) < 0.5 / Float(reelFPS)
        let wantPNG = wantPoster || sheetT.contains { abs(t - $0) < 0.5 / Float(reelFPS) }
        let (y8, y10, rgba) = ctx.encode(frame: view, wantRGBA: wantPNG, wantYUV: true)
        if let y8 { try h264In.write(contentsOf: y8) }
        if let y10 { try hevcIn.write(contentsOf: y10) }
        if let px = rgba {
            if wantPoster {
                try writeReelPNG(url: outDir.appendingPathComponent("poster.png"), width: reelW, height: reelH, rgba: px)
            } else {
                sheet.append(downscaleRGBA(px, width: reelW, height: reelH, factor: 4))
            }
        }
        if f % 60 == 0 {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            let line = String(format: "frame %d/%d (%.1fs)\n", f, n1, elapsed)
            let logURL = outDir.appendingPathComponent("progress.log")
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path),
                   let fh = try? FileHandle(forWritingTo: logURL) {
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: data)
                    try? fh.close()
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }

    try? h264In.close()
    try? hevcIn.close()
    h264Proc.waitUntilExit()
    hevcProc.waitUntilExit()

    if !sheet.isEmpty {
        let sw = reelW / 4
        let sh = reelH / 4
        let cols = 3
        let rows = (sheet.count + cols - 1) / cols
        let gap = 8
        let tw = sw * cols + gap * (cols - 1)
        let th = sh * rows + gap * (rows - 1)
        var img = [UInt8](repeating: 10, count: tw * th * 4)
        for (k, fr) in sheet.enumerated() {
            let cx = k % cols
            let cy = k / cols
            for y in 0..<sh {
                let sOff = y * sw * 4
                let dOff = ((cy * (sh + gap) + y) * tw + cx * (sw + gap)) * 4
                img[dOff..<(dOff + sw * 4)] = fr[sOff..<(sOff + sw * 4)]
            }
        }
        for i in stride(from: 3, to: img.count, by: 4) {
            img[i] = 255
        }
        try writeReelPNG(url: outDir.appendingPathComponent("breakdown-sheet.png"), width: tw, height: th, rgba: img)
    }
    let totalSec = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    FileHandle.standardError.write(Data(String(format: "rendered %d frames in %.1fs\n", max(n1 - n0, 0), totalSec).utf8))
#else
    _ = (reel, ctx, outDir, from, to)
    throw NSError(domain: "RuneLightReel", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg video render is only supported on macOS"])
#endif
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func runReelBench(reel: Reel, ctx: ReelCtx, outDir: URL, gpu: String) throws {
    var runs: [(LightTimings, Double)] = []
    for f in 0..<150 {
        let t: Float = 5.0 + Float(f % 60) / 60.0
        let (_, b) = try reel.frame(ctx: ctx, t: t, bench: true)
        if f >= 30, let tm = b.timings {
            runs.append((tm, b.glassMs))
        }
    }

    let st = reelState(t: 5.5)
    let built = buildReelUI(ts: ctx.ts, st: st)
    let g = reelGlassAt(t: reelTGlass + 1.5)!
    let lights = built.prims.compactMap { GlassLight.fromEmitter($0, z: 18.0 * reelS, gain: 0.9) }
    ctx.light.inspectCascades = false

    func one() throws {
        guard let cmd = ctx.queue.makeCommandBuffer() else { return }
        let scene = LightScene(prims: built.prims, lights: [], settings: reelGlowSettings(t: 5.5), emission: nil)
        ctx.light.render(scene: scene, commandBuffer: cmd, baseTexture: ctx.base, textTexture: ctx.text, targetTexture: ctx.lit)
        try ctx.glass.render(
            commandBuffer: cmd,
            glass: [g],
            lights: lights,
            settings: GlassSettings(),
            backdrop: ctx.lit,
            fluence: ctx.light.inspect().fluence,
            target: ctx.glassed
        )
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    try one()
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<120 {
        try one()
    }
    let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 120.0

    let field = median(runs.map { $0.0.field })
    let gi = median(runs.map { $0.0.gi })
    let scene = median(runs.map { $0.0.giScene })
    let fluence = median(runs.map { $0.0.fluence })
    let glass = median(runs.map { $0.1 })
    let cs = (0..<Int(lightCascades)).map { n in median(runs.map { $0.0.cascades[n] }) }

    var s = "{\n  \"gpu\": \"\(gpu)\",\n  \"resolution\": \"\(reelW)x\(reelH)\",\n"
    s += String(format: "  \"field\": %.4f,\n  \"gi\": %.4f,\n  \"gi_scene\": %.4f,\n", field, gi, scene)
    for (n, c) in cs.enumerated() {
        s += String(format: "  \"c%d\": %.4f,\n", n, c)
    }
    s += String(format: "  \"fluence\": %.4f,\n  \"glass\": %.4f,\n  \"frame\": %.4f\n}\n", fluence, glass, wall)
    print(s, terminator: "")
    try s.write(to: outDir.appendingPathComponent("bench.json"), atomically: true, encoding: .utf8)
}
#endif
