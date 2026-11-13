import Foundation
import RuneFX
import RuneRef

#if canImport(Metal)
import Metal
#endif

#if canImport(Metal)
private final class GalleryCtx {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let ui: UiRenderer
    let fx: FxRenderer
    let atlas: TextAtlas
    let sceneTex: MTLTexture
    let backdropTex: MTLTexture
    let outTex: MTLTexture
    let pyramid: MaskPyramid
    var srcTex: (MTLTexture, Int, Int)?
    let resolvePipeline: MTLRenderPipelineState
    let w: Int
    let h: Int

    init(w: Int, h: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RuneFxGallery", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
        }
        self.device = device
        self.queue = queue
        self.ui = try UiRenderer(device: device, pixelFormat: .rgba16Float)
        self.fx = try FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: false))
        self.atlas = TextAtlas()

        func makeTex(_ fmt: MTLPixelFormat, width: Int, height: Int, usage: MTLTextureUsage, storage: MTLStorageMode) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
            d.usage = usage
            d.storageMode = storage
            return device.makeTexture(descriptor: d)!
        }

        self.sceneTex = makeTex(.rgba16Float, width: w, height: h, usage: [.renderTarget, .shaderRead], storage: .private)
        self.backdropTex = makeTex(.rgba16Float, width: w, height: h, usage: [.shaderRead, .renderTarget], storage: .private)
        self.outTex = makeTex(.rgba8Unorm, width: w, height: h, usage: [.renderTarget, .shaderRead], storage: .shared)
        self.pyramid = try MaskPyramid(device: device, width: UInt32(w), height: UInt32(h))

        let lib = try device.makeLibrary(source: GalleryShaders.resolveMetalSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "resolve"
        pd.vertexFunction = lib.makeFunction(name: "vs_full")
        pd.fragmentFunction = lib.makeFunction(name: "fs_resolve")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        self.resolvePipeline = try device.makeRenderPipelineState(descriptor: pd)
        self.w = w
        self.h = h
    }

    private func pass(_ cmd: MTLCommandBuffer, target: MTLTexture, clear: MTLClearColor?) -> MTLRenderCommandEncoder? {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = (clear != nil) ? .clear : .load
        if let clear { rp.colorAttachments[0].clearColor = clear }
        rp.colorAttachments[0].storeAction = .store
        return cmd.makeRenderCommandEncoder(descriptor: rp)
    }

    func render(name: String, t: Float, reduced: Bool) throws -> [UInt8] {
        let b = GalleryBuilder(atlas: atlas, t: t, reduced: reduced)
        buildGalleryScene(name: name, into: b)

        var all = b.ui
        let maskRange = all.count..<(all.count + b.mask.count)
        all.append(contentsOf: b.mask)
        let srcRange = all.count..<(all.count + b.src.count)
        all.append(contentsOf: b.src)
        ui.prepare(atlas: atlas, insts: all)

        if let r = b.srcRect {
            let sw = max(1, Int((r.w + 2 * gallerySrcPad) * galleryS))
            let sh = max(1, Int((r.h + 2 * gallerySrcPad) * galleryS))
            if srcTex == nil || srcTex!.1 != sw || srcTex!.2 != sh {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: sw, height: sh, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                srcTex = (device.makeTexture(descriptor: d)!, sw, sh)
            }
        }

        var sources: [MTLTexture?] = [pyramid.texture]
        if let sTex = srcTex?.0 {
            sources.append(sTex)
        }
        let frame = FxFrame(
            viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            scale: galleryS,
            layers: b.layers,
            backdrop: backdropTex,
            sources: sources
        )
        _ = fx.prepare(frame: frame, slots: b.slots)

        let cmd = queue.makeCommandBuffer()!
        let transparent = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let black = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if !b.mask.isEmpty, let mask0 = pyramid.level(0) {
            if let enc = pass(cmd, target: mask0, clear: transparent) {
                ui.draw(encoder: enc, range: maskRange)
                enc.endEncoding()
            }
            try fx.buildMips(commandBuffer: cmd, pyramid: pyramid)
        }

        if let sTex = srcTex?.0, !b.src.isEmpty {
            if let enc = pass(cmd, target: sTex, clear: transparent) {
                ui.draw(encoder: enc, range: srcRange)
                enc.endEncoding()
            }
        }

        if let enc = pass(cmd, target: sceneTex, clear: black) {
            enc.endEncoding()
        }

        for op in b.ops {
            switch op {
            case .ui(let range):
                if let enc = pass(cmd, target: sceneTex, clear: nil) {
                    ui.draw(encoder: enc, range: range)
                    enc.endEncoding()
                }
            case .fx(let i):
                _ = try fx.blurBackdrop(commandBuffer: cmd, backdrop: backdropTex, layer: i)
                if let enc = pass(cmd, target: sceneTex, clear: nil) {
                    try fx.drawLayer(encoder: enc, layer: i)
                    enc.endEncoding()
                }
            case .backdrop:
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(
                        from: sceneTex,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: w, height: h, depth: 1),
                        to: backdropTex,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    blit.endEncoding()
                }
            }
        }

        if let enc = pass(cmd, target: outTex, clear: black) {
            enc.setRenderPipelineState(resolvePipeline)
            enc.setFragmentTexture(sceneTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        outTex.getBytes(&rgba, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return rgba
    }
}

private func halfDownsample(_ px: [UInt8], w: Int, h: Int) -> [UInt8] {
    let hw = w / 2
    let hh = h / 2
    var o = [UInt8](repeating: 0, count: hw * hh * 4)
    for y in 0..<hh {
        for x in 0..<hw {
            for c in 0..<4 {
                func s(_ dx: Int, _ dy: Int) -> UInt32 {
                    UInt32(px[((y * 2 + dy) * w + x * 2 + dx) * 4 + c])
                }
                o[(y * hw + x) * 4 + c] = UInt8((s(0, 0) + s(1, 0) + s(0, 1) + s(1, 1) + 2) / 4)
            }
        }
    }
    return o
}

private func stripTimes(_ name: String) -> (Float, Float) {
    switch name {
    case "motion": return (0.0, 0.6)
    case "glow", "pulse": return (0.0, 1.4)
    case "distort": return (0.0, 0.9)
    case "liquid-metal", "plastic", "mesh-gradient", "dither", "grain-gradient", "fluted-glass", "fills", "fill-presets":
        return (0.0, 4.0)
    default: return (1.0, 1.0)
    }
}

private func stillTime(_ name: String) -> Float {
    switch name {
    case "glow": return 0.3
    case "pulse": return 0.8
    case "electric": return 1.37
    case "fire": return 2.0
    case "motion": return 0.1
    case "distort": return 0.3
    case "liquid-metal", "plastic", "mesh-gradient", "dither", "grain-gradient", "fluted-glass", "fills", "fill-presets":
        return 1.2
    default: return 0.55
    }
}

private func renderEffect(ctx: GalleryCtx, dir: URL, name: String) throws {
    let (w, h) = (ctx.w, ctx.h)
    let px = try ctx.render(name: name, t: stillTime(name), reduced: false)
    try Frame(width: w, height: h, rgba: px).writePNG(to: dir.appendingPathComponent("\(name).png"))
    let pxRed = try ctx.render(name: name, t: stillTime(name), reduced: true)
    try Frame(width: w / 2, height: h / 2, rgba: halfDownsample(pxRed, w: w, h: h))
        .writePNG(to: dir.appendingPathComponent("\(name)-reduced.png"))

    let (t0, span) = stripTimes(name)
    let (fw, fh) = (w / 2, h / 2)
    var strip = [UInt8](repeating: 0, count: fw * 4 * fh * 2 * 4)
    for i in 0..<8 {
        let t = t0 + span * Float(i) / 8.0
        let f = halfDownsample(try ctx.render(name: name, t: t, reduced: false), w: w, h: h)
        let ox = (i % 4) * fw
        let oy = (i / 4) * fh
        for y in 0..<fh {
            let d = ((oy + y) * fw * 4 + ox) * 4
            let s = y * fw * 4
            strip.replaceSubrange(d..<(d + fw * 4), with: f[s..<(s + fw * 4)])
        }
    }
    try Frame(width: fw * 4, height: fh * 2, rgba: strip)
        .writePNG(to: dir.appendingPathComponent("\(name)-strip.png"))
    fputs("wrote \(name)\n", stderr)
}

private func timingLayers() -> [(String, FxLayer)] {
    let sh = FxShape.rounded(x: 60, y: 60, w: 480, h: 280, radius: 24)
    let t: Float = 1.3
    var v: [(String, FxLayer)] = [
        ("glow soft", Fx.glow(GlowParams(radius: 24)).on(sh)),
        ("glow neon", Fx.glow(GlowParams(style: .neon, radius: 24, inner: 0.4)).on(sh)),
        ("glow aura", Fx.glow(GlowParams(style: .aura, radius: 24, inner: 0.5)).on(sh)),
        ("glow mask (text)", Fx.glow(GlowParams(style: .mask, radius: 24)).on(sh).source(slot: 0, rect: FxRect(x: 0, y: 0, w: 600, h: 400))),
        ("pulse radar", Fx.pulse(PulseParams(reach: 80)).on(sh)),
        ("pulse breathe", Fx.pulse(PulseParams(style: .breathe, reach: 30)).on(sh)),
        ("pulse heartbeat", Fx.pulse(PulseParams(style: .heartbeat, reach: 60)).on(sh)),
        ("pulse ripple", Fx.pulse(PulseParams(style: .ripple(at: SIMD2<Float>(200, 200)), reach: 0, t0: 1, duration: 1)).on(sh)),
        ("electric arc (3 strands)", Fx.electric(ElectricParams(style: .arc(a: SIMD2<Float>(20, 200), b: SIMD2<Float>(580, 200)), glow: 40, strands: 3)).on(sh)),
        ("electric border", Fx.electric(ElectricParams(glow: 30)).on(sh)),
        ("electric charged", Fx.electric({ var p = ElectricParams.charged(); p.glow = 30; return p }()).on(sh)),
        ("fire top + 16 embers", Fx.fire(FireParams(height: 200)).on(FxShape.rounded(x: 60, y: 300, w: 480, h: 90, radius: 16))),
        ("fire plasma border", Fx.fire({ var p = FireParams.plasma(); p.height = 200; return p }()).on(sh)),
        ("fire heat (UI)", Fx.fire({ var p = FireParams.heat(); p.height = 200; return p }()).on(FxShape.rounded(x: 60, y: 300, w: 480, h: 90, radius: 16))),
        ("distort heat haze", Fx.distort(.heatHaze(height: 40, scale: 14, speed: 2, amount: 2, wholeShape: true)).on(FxShape.rounded(x: 0, y: 0, w: 600, h: 400, radius: 0))),
        ("distort shockwave", Fx.distort(.shockwave(at: SIMD2<Float>(300, 200), reach: 400, width: 14, amount: 9, chroma: 0.3, t0: 0.9, duration: 1)).on(sh)),
        ("distort lens", Fx.lens(LensParams()).on(FxShape.rounded(x: 20, y: 20, w: 560, h: 360, radius: 60))),
        ("distort lens + frost", Fx.lens(LensParams(frost: 0.6)).on(FxShape.rounded(x: 20, y: 20, w: 560, h: 360, radius: 60))),
        ("distort CRT", Fx.distort(.crt()).on(FxShape.rounded(x: 0, y: 0, w: 600, h: 400, radius: 12))),
        ("distort chroma split", Fx.distort(.chromaSplit(offset: SIMD2<Float>(2, 0))).on(FxShape.rounded(x: 0, y: 0, w: 600, h: 400, radius: 12))),
        ("shimmer (shape)", Fx.shimmer(ShimmerParams()).on(FxShape.rounded(x: 0, y: 0, w: 600, h: 400, radius: 12))),
        ("sparkles x9", Fx.sparkles(SparkleParams()).on(FxShape.rounded(x: 0, y: 0, w: 600, h: 400, radius: 12))),
        ("aurora", Fx.aurora(AuroraParams()).on(FxShape.rounded(x: 0, y: 0, w: 600, h: 400, radius: 12))),
        ("grain", Fx.grain(GrainParams()).on(FxShape.rounded(x: 0, y: 0, w: 600, h: 400, radius: 12))),
        ("fill liquid metal", Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.chrome()).intensity(1)).on(sh)),
        ("fill liquid metal, still", Fx.fill(FillStyle.liquidMetal({ var p = LiquidMetalParams.chrome(); p.flow = 0; return p }()).intensity(1)).on(sh)),
        ("fill liquid metal border 8", Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.gold()).border(8)).on(sh)),
        ("fill liquid metal, element anchor", Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.chrome().anchor(.element)).intensity(1)).on(sh)),
        ("fill plastic glossy", Fx.fill(FillStyle.plastic(PlasticParams.glossy()).intensity(1)).on(sh)),
        ("fill plastic matte", Fx.fill(FillStyle.plastic(PlasticParams.matte()).intensity(1)).on(sh)),
        ("fill plastic border 8", Fx.fill(FillStyle.plastic(PlasticParams.glossy()).border(8)).on(sh)),
        ("fill mesh gradient (5 colours)", Fx.fill(FillStyle.meshGradient(MeshGradientParams.dusk()).intensity(1)).on(sh)),
        ("fill dither bayer (ramp)", Fx.fill(FillStyle.dither(DitherParams.bayer()).intensity(1)).on(sh)),
        ("fill dither blue noise (radial)", Fx.fill(FillStyle.dither(DitherParams.grain()).intensity(1)).on(sh)),
        ("fill dither palette (noise)", Fx.fill(FillStyle.dither(DitherParams.handheld()).intensity(1)).on(sh)),
        ("fill dither backdrop", Fx.fill(FillStyle.dither(DitherParams.backdrop()).intensity(1)).on(sh)),
        ("fill grain gradient", Fx.fill(FillStyle.grainGradient(GrainGradientParams.ember()).intensity(1)).on(sh)),
        ("fill grain gradient conic, colour", Fx.fill(FillStyle.grainGradient(GrainGradientParams.sweep()).intensity(1)).on(sh)),
        ("fill fluted glass", Fx.fill(FillStyle.flutedGlass(FlutedGlassParams.reeded()).intensity(1)).on(sh)),
        ("fill fluted glass + frost", Fx.fill(FillStyle.flutedGlass(FlutedGlassParams.frosted()).intensity(1)).on(sh)),
        ("fill metaballs x6", Fx.fill(FillStyle.metaballs(MetaballParams.lava()).intensity(1)).on(sh)),
        ("fill swirl", Fx.fill(FillStyle.swirl(SwirlParams.ink()).intensity(1)).on(sh)),
        ("fill voronoi", Fx.fill(FillStyle.voronoi(VoronoiParams.cells()).intensity(1)).on(sh)),
        ("fill waves (5 bands)", Fx.fill(FillStyle.waves(WaveParams.sea()).intensity(1)).on(sh)),
        ("fill halftone (radial)", Fx.fill(FillStyle.halftone(HalftoneParams.print()).intensity(1)).on(sh)),
        ("fill halftone backdrop", Fx.fill(FillStyle.halftone(HalftoneParams.backdrop()).intensity(1)).on(sh)),
    ]
    for (n, mode, angle) in [("motion shutter (fling peak)", BlurMode.shutter, Float(360)), ("motion directional", BlurMode.directional, Float(360))] {
        let rest = FxRect(x: 100, y: 100, w: 400, h: 200)
        let p = MotionBlurParams(mode: mode, shutterAngle: angle)
        let s = MotionSamples.fromTrack(p, rest: rest, at: 0.02, scale: galleryS, track: galleryFling)
        v.append((n, Fx.motionBlur(p, s).on(FxShape.rounded(x: rest.x, y: rest.y, w: rest.w, h: rest.h, radius: 14)).source(slot: 1, rect: rest.inflate(gallerySrcPad))))
    }
    return v.map { ($0.0, $0.1.at(t)) }
}

private let timingDraws = 10

private func runTimings() throws -> String {
    let w = Int(600 * galleryS)
    let h = Int(400 * galleryS)
    let ctx = try GalleryCtx(w: w, h: h)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 808, height: 408, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .private
    let srcTex = ctx.device.makeTexture(descriptor: d)!

    var out = "| effect | covered px (2x) | reads/px | noise/px | backdrop | GPU ms per draw (median; 10 draws/pass) |\n|---|---:|---:|---:|:-:|---:|\n"
    for (name, layer) in timingLayers() {
        let layers = [layer]
        let frame = FxFrame(
            viewport: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            scale: galleryS,
            layers: layers,
            backdrop: ctx.backdropTex,
            sources: [ctx.pyramid.texture, srcTex]
        )
        let graph = ctx.fx.prepare(frame: frame)
        var samples: [Double] = []
        for round in 0..<4 {
            for _ in 0..<4 {
                let cmd = ctx.queue.makeCommandBuffer()!
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = ctx.sceneTex
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rp.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                    for _ in 0..<timingDraws {
                        try ctx.fx.drawLayer(encoder: enc, layer: 0)
                    }
                    enc.endEncoding()
                }
                cmd.commit()
                cmd.waitUntilCompleted()
                if round > 0 {
                    let dt = cmd.gpuEndTime - cmd.gpuStartTime
                    if dt > 0 {
                        samples.append(dt * 1e3 / Double(timingDraws))
                    }
                }
            }
        }
        samples.sort()
        let med = samples.isEmpty ? Double.nan : samples[samples.count / 2]
        let c = layer.fx.cost
        out += String(format: "| %@ | %llu | %u | %u | %@ | %.3f |\n", name, graph.stats.pixels, c.samples, c.alu, c.backdrop ? "yes" : "", med)
    }
    return out
}
#endif

@main
enum RuneFxGalleryApp {
    static func main() throws {
        try run(args: Array(CommandLine.arguments.dropFirst()))
    }

    static func run(args: [String]) throws {
        func arg(_ key: String) -> String? {
            guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }

        if args.contains("--list-effects") {
            for e in galleryEffects + ["blend"] {
                print(e)
            }
            return
        }

        let effect = arg("--effect") ?? arg("--still")
        let stillOnly = args.contains("--still")
        let snapPath = arg("--snap")
        let dir = URL(fileURLWithPath: arg("--out") ?? "demo/fx", isDirectory: true)
        let reduced = args.contains("--reduced")

        #if canImport(Metal)
        if args.contains("--timings") {
            let t = try runTimings()
            print(t)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try t.write(to: dir.appendingPathComponent("timings.md"), atomically: true, encoding: .utf8)
            return
        }

        let ctx = try GalleryCtx(w: Int(galleryW * galleryS), h: Int(galleryH * galleryS))

        if let snapPath {
            let name = effect ?? "glow"
            let t = arg("--t").flatMap(Float.init) ?? stillTime(name)
            let px = try ctx.render(name: name, t: t, reduced: reduced)
            let url = URL(fileURLWithPath: snapPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Frame(width: ctx.w, height: ctx.h, rgba: px).writePNG(to: url)
            return
        }

        if let framesDir = arg("--frames") {
            let fps: Float = arg("--fps").flatMap(Float.init) ?? 60.0
            let secs: Float = arg("--seconds").flatMap(Float.init) ?? 2.0
            let start: Float = arg("--start").flatMap(Float.init) ?? 0.0
            guard let name = effect else {
                fputs("error: --frames requires --effect NAME\n", stderr)
                Foundation.exit(1)
            }
            let outURL = URL(fileURLWithPath: framesDir, isDirectory: true)
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            let n = Int((fps * secs).rounded())
            for i in 0..<n {
                let px = try ctx.render(name: name, t: start + Float(i) / fps, reduced: reduced)
                let filename = String(format: "%@_%04d.png", name, i)
                try Frame(width: ctx.w, height: ctx.h, rgba: px).writePNG(to: outURL.appendingPathComponent(filename))
            }
            fputs("wrote \(n) frames to \(framesDir)\n", stderr)
            return
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if stillOnly {
            let name = effect ?? "blend"
            let px = try ctx.render(name: name, t: stillTime(name), reduced: reduced)
            try Frame(width: ctx.w, height: ctx.h, rgba: px).writePNG(to: dir.appendingPathComponent("\(name).png"))
            fputs("wrote \(name).png\n", stderr)
            return
        }

        let list = effect.map { [$0] } ?? galleryEffects
        for e in list {
            try renderEffect(ctx: ctx, dir: dir, name: e)
        }
        if effect == nil && !args.contains("--no-timings") {
            let t = try runTimings()
            print(t)
            try t.write(to: dir.appendingPathComponent("timings.md"), atomically: true, encoding: .utf8)
        }
        #else
        fputs("error: Metal unavailable on this platform\n", stderr)
        Foundation.exit(1)
        #endif
    }
}
