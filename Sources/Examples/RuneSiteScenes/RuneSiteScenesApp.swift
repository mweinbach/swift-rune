import Foundation
#if canImport(Metal)
import Metal
#endif
import Rune
import RuneFX
import RuneLight
import RuneRef

/// Port of `examples/site-scenes`: the material stills on Rune's home page (`www/`),
/// rendered headlessly at 2x (1920x1080): liquid metal from `RuneFX`, and glass and light
/// from `RuneLight`, over linear-light backdrop/pool/shadow frames resolved with TPDF dither.
///
/// Usage: `rune-site-scenes [--out target/site-scenes] [--only NAME] [--t SECONDS]`
/// Also supports `--list-scenes` and `--snap PATH [--scene NAME]` for headless parity tooling.
private let wPt: Float = 960.0
private let hPt: Float = 540.0
private let scaleFactor: Float = 2.0
private let pxW: Int = Int(wPt * scaleFactor)
private let pxH: Int = Int(hPt * scaleFactor)
private let hue: Float = 245.0
private let sceneNames = ["metal", "glass", "light"]

private func pxRect(_ r: SIMD4<Float>) -> SIMD4<Float> {
    r * scaleFactor
}

private func lin(_ c: Color) -> SIMD3<Float> {
    SIMD3<Float>(c.r, c.g, c.b)
}

private enum PaintOp {
    case rect(SIMD4<Float>, Float, Color)
    case shadow(SIMD4<Float>, Float, Float, Color)
    case pool(Float, Float, Float, Float, Color)
}

private struct SitePaint {
    var ops: [PaintOp] = []
    var prims: [Prim] = []

    mutating func rect(_ r: SIMD4<Float>, radius: Float, _ c: Color) {
        ops.append(.rect(r, radius, c))
    }

    mutating func solid(_ r: SIMD4<Float>, radius: Float, _ c: Color, _ build: (Prim) -> Prim) {
        rect(r, radius: radius, c)
        let pr = pxRect(r)
        let p = Prim.rect(pr.x, pr.y, pr.z, pr.w)
            .radius(radius * scaleFactor)
            .albedo(lin(c))
        prims.append(build(p))
    }

    mutating func shadow(_ r: SIMD4<Float>, radius: Float, sigma: Float, _ c: Color) {
        ops.append(.shadow(r, radius, sigma, c))
    }

    mutating func pool(cx: Float, cy: Float, rx: Float, ry: Float, _ c: Color) {
        ops.append(.pool(cx, cy, rx, ry, c))
    }

    mutating func backdrop() {
        pool(cx: wPt * 0.5, cy: hPt * 0.5, rx: wPt * 0.62, ry: hPt * 0.9, oklcha(0.2, 0.012, hue, 0.5))
    }

    /// Rasterizes `ops` in linear premultiplied RGBA16F (`pxW x pxH`).
    func rasterizeLinearFloat16(clear: Color) -> [Float16] {
        var buf = [SIMD4<Float>](
            repeating: SIMD4<Float>(clear.r, clear.g, clear.b, 1.0),
            count: pxW * pxH
        )

        @inline(__always)
        func blend(_ idx: Int, _ src: SIMD4<Float>) {
            let a = src.w
            if a <= 0 { return }
            let dst = buf[idx]
            let inv = 1.0 - a
            buf[idx] = SIMD4<Float>(
                src.x + dst.x * inv,
                src.y + dst.y * inv,
                src.z + dst.z * inv,
                a + dst.w * inv
            )
        }

        for op in ops {
            switch op {
            case let .pool(cxPt, cyPt, rxPt, ryPt, c):
                let cx = cxPt * scaleFactor
                let cy = cyPt * scaleFactor
                let rx = max(1e-3, rxPt * scaleFactor)
                let ry = max(1e-3, ryPt * scaleFactor)
                let invRx = 1.0 / rx
                let invRy = 1.0 / ry
                let x0 = max(0, Int(floorf(cx - rx)))
                let x1 = min(pxW, Int(ceilf(cx + rx)))
                let y0 = max(0, Int(floorf(cy - ry)))
                let y1 = min(pxH, Int(ceilf(cy + ry)))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 {
                    let dy = (Float(y) + 0.5 - cy) * invRy
                    let dy2 = dy * dy
                    if dy2 >= 1.0 { continue }
                    let rowBase = y * pxW
                    for x in x0..<x1 {
                        let dx = (Float(x) + 0.5 - cx) * invRx
                        let t2 = dx * dx + dy2
                        if t2 >= 1.0 { continue }
                        let oneMinus = 1.0 - t2
                        let f = oneMinus * oneMinus * oneMinus
                        let a = c.a * f
                        blend(rowBase + x, SIMD4<Float>(c.r * a, c.g * a, c.b * a, a))
                    }
                }

            case let .shadow(rPt, radiusPt, sigmaPt, c):
                let r = pxRect(rPt)
                let rad = radiusPt * scaleFactor
                let blur = sigmaPt * 2.0 * scaleFactor
                let pad = ceilf(sigmaPt * 3.0 * scaleFactor + 2.0)
                let half = SIMD2<Float>(r.z * 0.5, r.w * 0.5)
                let center = SIMD2<Float>(r.x + half.x, r.y + half.y)
                let x0 = max(0, Int(floorf(r.x - pad)))
                let x1 = min(pxW, Int(ceilf(r.x + r.z + pad)))
                let y0 = max(0, Int(floorf(r.y - pad)))
                let y1 = min(pxH, Int(ceilf(r.y + r.w + pad)))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 {
                    let rowBase = y * pxW
                    let py = Float(y) + 0.5 - center.y
                    for x in x0..<x1 {
                        let px = Float(x) + 0.5 - center.x
                        let cov = RefShader.gaussianShadowCoverage(
                            p: SIMD2<Float>(px, py),
                            halfSize: half,
                            radius: rad,
                            blur: blur
                        )
                        if cov <= 0 { continue }
                        let a = c.a * cov
                        blend(rowBase + x, SIMD4<Float>(c.r * a, c.g * a, c.b * a, a))
                    }
                }

            case let .rect(rPt, radiusPt, c):
                let r = pxRect(rPt)
                let rad = SIMD4<Float>(repeating: radiusPt * scaleFactor)
                let half = SIMD2<Float>(r.z * 0.5, r.w * 0.5)
                let center = SIMD2<Float>(r.x + half.x, r.y + half.y)
                let x0 = max(0, Int(floorf(r.x - 1.0)))
                let x1 = min(pxW, Int(ceilf(r.x + r.z + 1.0)))
                let y0 = max(0, Int(floorf(r.y - 1.0)))
                let y1 = min(pxH, Int(ceilf(r.y + r.w + 1.0)))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 {
                    let rowBase = y * pxW
                    let py = Float(y) + 0.5 - center.y
                    for x in x0..<x1 {
                        let px = Float(x) + 0.5 - center.x
                        let sd = RefShader.sdBox(SIMD2<Float>(px, py), halfSize: half, radii: rad)
                        let cov = RefShader.boxCoverage(sd)
                        if cov <= 0 { continue }
                        let a = c.a * cov
                        blend(rowBase + x, SIMD4<Float>(c.r * a, c.g * a, c.b * a, a))
                    }
                }
            }
        }

        var out = [Float16](repeating: Float16(0), count: pxW * pxH * 4)
        for i in 0..<(pxW * pxH) {
            let v = buf[i]
            let j = i * 4
            out[j] = Float16(v.x)
            out[j + 1] = Float16(v.y)
            out[j + 2] = Float16(v.z)
            out[j + 3] = Float16(v.w)
        }
        return out
    }
}

#if canImport(Metal)
private let resolveMetalSource = """
#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 pos [[position]];
};

vertex VSOut resolve_vs(uint vi [[vertex_id]]) {
    VSOut out;
    float2 p = float2(float((vi << 1u) & 2u), float(vi & 2u));
    out.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static inline uint pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

static inline float u01(uint n) {
    return float(pcg(n) >> 8u) * (1.0 / 16777216.0);
}

static inline float3 to_srgb(float3 c) {
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(max(c, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
    return select(hi, lo, c <= float3(0.0031308));
}

fragment float4 resolve_fs(VSOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    uint2 ip = uint2(in.pos.xy);
    float4 c = scene.read(ip);
    float n = u01(ip.x + pcg(ip.y)) + u01(ip.x * 7919u + pcg(ip.y + 104729u)) - 1.0;
    float3 s = to_srgb(clamp(c.rgb, float3(0.0), float3(1.0))) + float3(n / 255.0);
    return float4(clamp(s, float3(0.0), float3(1.0)), 1.0);
}
"""

private final class SiteCtx {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let base: MTLTexture
    let text: MTLTexture
    let glassed: MTLTexture
    let pyr: MTLTexture
    let out: MTLTexture
    let resolvePipeline: MTLRenderPipelineState

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            return nil
        }
        self.device = dev
        self.queue = q

        func makeTex(_ format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: pxW,
                height: pxH,
                mipmapped: false
            )
            desc.usage = usage
            desc.storageMode = .shared
            return dev.makeTexture(descriptor: desc)
        }

        guard let base = makeTex(.rgba16Float, usage: [.renderTarget, .shaderRead]),
              let text = makeTex(.rgba16Float, usage: [.renderTarget, .shaderRead]),
              let glassed = makeTex(.rgba16Float, usage: [.renderTarget, .shaderRead]),
              let pyr = makeTex(.rgba16Float, usage: [.renderTarget, .shaderRead]),
              let out = makeTex(.rgba8Unorm, usage: [.renderTarget, .shaderRead]),
              let lib = try? dev.makeLibrary(source: resolveMetalSource, options: nil),
              let vs = lib.makeFunction(name: "resolve_vs"),
              let fs = lib.makeFunction(name: "resolve_fs") else {
            return nil
        }

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "resolve"
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        guard let resolvePipeline = try? dev.makeRenderPipelineState(descriptor: pd) else {
            return nil
        }

        self.base = base
        self.text = text
        self.glassed = glassed
        self.pyr = pyr
        self.out = out
        self.resolvePipeline = resolvePipeline
    }

    func draw(_ paint: SitePaint, clear: Color) {
        // Phase 2 (@render): can swap to MetalRenderer.encode(scene:into:base, commandBuffer:) once exposed.
        let pixels = paint.rasterizeLinearFloat16(clear: clear)
        pixels.withUnsafeBytes { raw in
            base.replace(
                region: MTLRegionMake2D(0, 0, pxW, pxH),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: pxW * 8
            )
        }
        let zero = [Float16](repeating: Float16(0), count: pxW * pxH * 4)
        zero.withUnsafeBytes { raw in
            text.replace(
                region: MTLRegionMake2D(0, 0, pxW, pxH),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: pxW * 8
            )
        }
    }

    func readRGBA8(from tex: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: pxW * pxH * 4)
        tex.getBytes(&bytes, bytesPerRow: pxW * 4, from: MTLRegionMake2D(0, 0, pxW, pxH), mipmapLevel: 0)
        return bytes
    }

    func resolve(_ src: MTLTexture) -> [UInt8] {
        guard let cmd = queue.makeCommandBuffer() else {
            return [UInt8](repeating: 0, count: pxW * pxH * 4)
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = out
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(resolvePipeline)
            enc.setFragmentTexture(src, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return readRGBA8(from: out)
    }

    func renderMetal(t: Float) -> [UInt8] {
        let cx = wPt * 0.5
        let cy = hPt * 0.5
        let r: Float = 92.0
        let box = SIMD4<Float>(cx - r, cy - r, 2.0 * r, 2.0 * r)
        var paint = SitePaint()
        paint.backdrop()
        paint.pool(cx: cx, cy: box.y + box.w + 6.0, rx: box.z * 0.62, ry: 26.0, oklcha(0.42, 0.09, hue, 0.22))
        paint.shadow(SIMD4<Float>(box.x + 8.0, box.y + 18.0, box.z - 16.0, box.w), radius: r, sigma: 22.0, oklcha(0.0, 0.0, 0.0, 0.85))
        draw(paint, clear: oklch(0.0, 0.0, 0.0))

        var params = LiquidMetalParams.chrome()
        params.tint = rgb(0xe4e9f0)
        params.light = rgb(0xd8e6ff)
        params.flow = 0.12
        params.scale = 180.0
        params.speed = 0.2
        params.bevel = 18.0
        params.dome = 0.85
        params.angle = -0.5
        params.iridescence = 0.0
        params.contrast = 1.2
        params.anchor = .element

        if let fx = try? FxRenderer(device: device, pixelFormat: .rgba16Float, options: FxOptions(dither: false, srgbBlend: false)),
           let cmd = queue.makeCommandBuffer() {
            let vp = SIMD2<UInt32>(UInt32(pxW), UInt32(pxH))
            let layer = FxLayer(
                fx: .fill(FillParams(FillStyle.liquidMetal(params))),
                shape: .circle(cx: cx, cy: cy, r: r),
                time: t
            )
            let graph = fx.prepare(viewport: vp, scale: scaleFactor, layers: [layer])
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = base
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                try? fx.encode(graph: graph, viewport: vp, encoder: enc)
                enc.endEncoding()
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return resolve(base)
    }

    func renderGlass(t: Float) -> [UInt8] {
        let cx = wPt * 0.5
        let cy = hPt * 0.5
        let orbs: [(Float, Float, Float, Color)] = [
            (cx - 48.0, cy - 50.0, 100.0, oklch(0.62, 0.16, hue)),
        ]
        var paint = SitePaint()
        paint.backdrop()
        for (ox, oy, rad, c) in orbs {
            let x = ox + sinf(t * 0.35 + ox) * 6.0
            let y = oy + cosf(t * 0.3 + oy) * 4.0
            paint.pool(cx: x, cy: y, rx: rad * 2.4, ry: rad * 2.4, Color(r: c.r, g: c.g, b: c.b, a: 0.3))
            paint.rect(SIMD4<Float>(x - rad, y - rad, 2.0 * rad, 2.0 * rad), radius: rad, c)
        }
        draw(paint, clear: oklch(0.0, 0.0, 0.0))

        let k = scaleFactor
        let pane = SIMD4<Float>(cx - 70.0, cy - 110.0, 220.0, 220.0)
        if let gl = try? GlassRenderer(device: device, pixelFormat: .rgba16Float),
           let cmd = queue.makeCommandBuffer() {
            let pyrRpd = MTLRenderPassDescriptor()
            pyrRpd.colorAttachments[0].texture = pyr
            pyrRpd.colorAttachments[0].loadAction = .clear
            pyrRpd.colorAttachments[0].storeAction = .store
            pyrRpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pyrRpd) {
                enc.setRenderPipelineState(gl.pyramidPipeline)
                enc.setFragmentTexture(base, index: 0)
                var texel = SIMD4<Float>(1.0 / Float(pxW), 1.0 / Float(pxH), 0, 0)
                enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }

            let slab = Glass.rounded(pane.x * k, pane.y * k, pane.z * k, pane.w * k, radius: 50.0 * k)
                .thickness(40.0 * k)
                .bevel(34.0 * k)
                .dome(6.0 * k)
                .gap(16.0 * k)
                .ior(1.5)
                .dispersion(0.025)
                .frost(0.6)
                .tint(SIMD3<Float>(0.0005, 0.00035, 0.0002))
            let lamp = GlassLight(
                pos: SIMD4<Float>((pane.x + pane.z * 0.3) * k, (pane.y - 220.0) * k, 420.0 * k, 260.0 * k),
                color: SIMD4<Float>(0.9, 1.0, 1.15, 0.0)
            )
            let settings = GlassSettings(env: 0.45, shadow: 0.6, shadowOffset: SIMD2<Float>(0, 24.0 * k), shadowBlur: 36.0 * k, caustic: 0.5)
            var uniforms = GlassUniforms()
            uniforms.size = SIMD4<Float>(Float(pxW), Float(pxH), 1.0 / Float(pxW), 1.0 / Float(pxH))
            uniforms.misc = SIMD4<Float>(1, 1, settings.env, settings.caustic)
            uniforms.shadow = SIMD4<Float>(settings.shadowOffset.x, settings.shadowOffset.y, settings.shadowBlur, settings.shadow)

            let mainRpd = MTLRenderPassDescriptor()
            mainRpd.colorAttachments[0].texture = glassed
            mainRpd.colorAttachments[0].loadAction = .clear
            mainRpd.colorAttachments[0].storeAction = .store
            mainRpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let enc = cmd.makeRenderCommandEncoder(descriptor: mainRpd) {
                enc.setRenderPipelineState(gl.mainPipeline)
                enc.setFragmentTexture(base, index: 0)
                enc.setFragmentTexture(pyr, index: 1)
                enc.setFragmentTexture(text, index: 2)
                var slabs = [slab]
                var lights = [lamp]
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<GlassUniforms>.stride, index: 0)
                enc.setFragmentBytes(&slabs, length: MemoryLayout<Glass>.stride, index: 1)
                enc.setFragmentBytes(&lights, length: MemoryLayout<GlassLight>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return resolve(glassed)
    }

    func renderLight(t: Float) -> [UInt8] {
        let cx = wPt * 0.5
        let cy = hPt * 0.5
        var paint = SitePaint()
        paint.pool(cx: cx, cy: cy, rx: wPt * 0.46, ry: hPt * 0.8, oklch(0.15, 0.004, hue))
        let s: Float = 60.0
        let gap: Float = 16.0
        let k = scaleFactor
        for i in 0..<3 {
            for j in 0..<3 {
                let x = cx - 1.5 * s - gap + Float(j) * (s + gap)
                let y = cy - 1.5 * s - gap + Float(i) * (s + gap)
                let lit = i == 1 && j == 1
                let c = lit ? oklch(0.55, 0.15, hue) : oklch(0.4, 0.005, hue)
                paint.solid(SIMD4<Float>(x, y, s, s), radius: 16.0, c) { p in
                    let raised = p.raised(12.0 * k).bevel(width: 12.0 * k, height: 4.0 * k).gloss(0.8, roughness: 0.3)
                    return lit ? raised.emissive(SIMD3<Float>(0.006, 0.024, 0.08)) : raised
                }
            }
        }
        draw(paint, clear: oklch(0.0, 0.0, 0.0))

        let a: Float = -2.25 + 0.12 * sinf(t * 0.5)
        let key = Light.point((cx + 150.0 * cosf(a)) * k, (cy + 130.0 * sinf(a)) * k, 200.0 * k)
            .color(lin(oklch(0.97, 0.012, hue)))
            .intensity(2.6)
            .radius(40.0 * k)
            .range(1000.0 * k)
            .specular(2.6)
        let fill = Light.point((cx + 420.0) * k, (cy - 300.0) * k, 420.0 * k)
            .color(lin(oklch(0.72, 0.12, hue)))
            .intensity(0.35)
            .radius(160.0 * k)
            .range(2400.0 * k)
            .specular(0.8)
        let settings = LightSettings(
            ambient: SIMD3<Float>(0.06, 0.06, 0.07),
            gi: GIParams(),
            backgroundGloss: 0.35,
            backgroundRoughness: 0.6,
            contactAO: 0.55,
            rim: 1.1,
            time: t
        )

        if let lights = try? LightRenderer(device: device, width: UInt32(pxW), height: UInt32(pxH), outputFormat: .rgba8Unorm),
           let cmd = queue.makeCommandBuffer() {
            let scene = LightScene(prims: paint.prims, lights: [key, fill], settings: settings)
            _ = lights.render(scene: scene, commandBuffer: cmd, baseTexture: base, textTexture: text, targetTexture: out)
            cmd.commit()
            cmd.waitUntilCompleted()
            return readRGBA8(from: out)
        }
        return [UInt8](repeating: 0, count: pxW * pxH * 4)
    }

    func render(name: String, t: Float) -> [UInt8] {
        switch name {
        case "metal": return renderMetal(t: t)
        case "glass": return renderGlass(t: t)
        case "light": return renderLight(t: t)
        default: fatalError("unknown scene \(name); scenes: \(sceneNames.joined(separator: ", "))")
        }
    }
}
#endif

@main
public enum RuneSiteScenesApp {
    public enum CLIError: Error, CustomStringConvertible {
        case metalUnavailable
        case unknownScene(String)

        public var description: String {
            switch self {
            case .metalUnavailable:
                return "error: Metal unavailable for site-scenes"
            case .unknownScene(let name):
                return "error: unknown scene \(name); scenes: \(sceneNames.joined(separator: ", "))"
            }
        }
    }

    public static let availableScenes = sceneNames

    @discardableResult
    public static func runCLI(arguments args: [String] = Array(CommandLine.arguments.dropFirst())) throws -> [URL] {
        if args.contains("--list-scenes") {
            for name in sceneNames {
                print(name)
            }
            return []
        }

        func argValue(_ key: String) -> String? {
            guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }

        let t: Float = argValue("--t").flatMap(Float.init) ?? 1.2
        let snapPath = argValue("--snap")
        let snapScene = argValue("--scene") ?? "metal"
        let outDir = URL(fileURLWithPath: argValue("--out") ?? "target/site-scenes", isDirectory: true)
        let only = argValue("--only")

        #if canImport(Metal)
        guard let ctx = SiteCtx() else {
            throw CLIError.metalUnavailable
        }

        if let snapPath {
            guard sceneNames.contains(snapScene) else {
                throw CLIError.unknownScene(snapScene)
            }
            let rgba = ctx.render(name: snapScene, t: t)
            let url = URL(fileURLWithPath: snapPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Frame(width: pxW, height: pxH, rgba: rgba).writePNG(to: url)
            return [url]
        }

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let targets = sceneNames.filter { only == nil || $0 == only }
        if targets.isEmpty, let only {
            throw CLIError.unknownScene(only)
        }
        var written: [URL] = []
        for name in targets {
            let rgba = ctx.render(name: name, t: t)
            let dest = outDir.appendingPathComponent("\(name).png")
            try Frame(width: pxW, height: pxH, rgba: rgba).writePNG(to: dest)
            fputs("wrote \(name).png\n", stderr)
            written.append(dest)
        }
        return written
        #else
        throw CLIError.metalUnavailable
        #endif
    }

    public static func main() throws {
        do {
            _ = try runCLI()
        } catch let err as CLIError {
            RuneStandardIO.error("\(err.description)\n")
            Foundation.exit(1)
        }
    }
}
