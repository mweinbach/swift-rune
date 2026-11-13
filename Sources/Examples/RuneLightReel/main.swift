import Foundation

#if canImport(Metal)
import Metal
#endif

@main
struct RuneLightReelApp {
    static func main() throws {
        #if !canImport(Metal)
        fputs("rune-light-reel requires Metal.\n", stderr)
        #else
        let args = Array(CommandLine.arguments.dropFirst())
        var cmd: String?
        var outDir = URL(fileURLWithPath: "demo/reel")
        var from: Float = 0.0
        var to: Float = reelDuration
        var times: [Float] = []
        var snapPath: String?
        var snapTime: Float = 5.5

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--snap":
                i += 1
                if i < args.count { snapPath = args[i] }
            case "--t":
                i += 1
                if i < args.count { snapTime = Float(args[i]) ?? snapTime }
            case "--out":
                i += 1
                if i < args.count { outDir = URL(fileURLWithPath: args[i]) }
            case "--from":
                i += 1
                if i < args.count { from = Float(args[i]) ?? from }
            case "--to":
                i += 1
                if i < args.count { to = Float(args[i]) ?? to }
            case "render", "stills", "bench":
                if cmd == nil { cmd = a }
            default:
                if cmd == "stills" && times.isEmpty {
                    times = a.split(separator: ",").compactMap { Float($0) }
                }
            }
            i += 1
        }

        let ctx = try ReelCtx()
        let benchEnv = ProcessInfo.processInfo.environment["REEL_BENCH"] ?? "demo/reel"
        let hp0 = dpx(620.0, 421.0, 0.0, 0.0)
        let hp1 = dpx(912.0, 300.0, 0.0, 0.0)
        let reel = Reel(
            bench: loadReelBench(outDir: URL(fileURLWithPath: benchEnv)),
            hp: [SIMD2<Float>(hp0.x, hp0.y), SIMD2<Float>(hp1.x, hp1.y)]
        )

        if let snapPath {
            let (view, _) = try reel.frame(ctx: ctx, t: snapTime, bench: false)
            let (_, _, rgba) = ctx.encode(frame: view, wantRGBA: true, wantYUV: false)
            if let rgba {
                try writeReelPNG(url: URL(fileURLWithPath: snapPath), width: reelW, height: reelH, rgba: rgba)
            }
            return
        }

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        switch cmd ?? "stills" {
        case "bench":
            let gpu = ProcessInfo.processInfo.environment["REEL_GPU"] ?? ctx.gpuName
            try runReelBench(reel: reel, ctx: ctx, outDir: outDir, gpu: gpu)
        case "stills":
            let targets = times.isEmpty ? [5.5] : times
            for t in targets {
                let (view, _) = try reel.frame(ctx: ctx, t: t, bench: false)
                let (_, _, rgba) = ctx.encode(frame: view, wantRGBA: true, wantYUV: false)
                if let rgba {
                    let url = outDir.appendingPathComponent(String(format: "still-%05.2f.png", t))
                    try writeReelPNG(url: url, width: reelW, height: reelH, rgba: rgba)
                }
                fputs("still \(t)\n", stderr)
            }
        case "render":
            try runReelRender(reel: reel, ctx: ctx, outDir: outDir, from: from, to: to)
        default:
            break
        }
        #endif
    }
}
