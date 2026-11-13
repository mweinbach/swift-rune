import Foundation
import Rune
import RuneLight
import RuneMotion
import RuneRef

#if canImport(Metal)
import Metal
#endif

let demoW: Int = 2560
let demoH: Int = 1600
let demoFPS: Int = 60

func demoLinear(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
    SIMD3<Float>(RefShader.srgbToLinear(r), RefShader.srgbToLinear(g), RefShader.srgbToLinear(b))
}

struct SpringTrack: Sendable {
    var t0: Double
    var x0: Float
    var v0: Float
    var target: Float
    var spring: Spring

    static func at(_ v: Float) -> SpringTrack {
        SpringTrack(t0: 0.0, x0: v, v0: 0.0, target: v, spring: Spring(duration: 0.3, bounce: 0.0))
    }

    func sample(at t: Double) -> (position: Float, velocity: Float) {
        spring.sample(from: x0, velocity: v0, target: target, at: Float(max(t - t0, 0.0)))
    }

    func value(at t: Double) -> Float {
        sample(at: t).position
    }

    mutating func retarget(at t: Double, target: Float, spring: Spring) {
        let (x, v) = sample(at: t)
        self = SpringTrack(t0: t, x0: x, v0: v, target: target, spring: spring)
    }
}

struct DemoUIInst: Sendable {
    var rect: SIMD4<Float>   // px x, y, w, h
    var radii: SIMD4<Float>  // px tl, tr, br, bl
    var fill: SIMD4<Float>   // premultiplied linear
    var border: SIMD4<Float> // premultiplied linear
    var params: SIMD4<Float> // bw, kind (0 rect, 1 glyph), 0, 1
    var uv: SIMD4<Float>     // atlas uv u0, v0, u1, v1
    var vp: SIMD4<Float>     // viewport px w, h, 0, 0
}

#if canImport(Metal)
private let demoUIMetalSource = """
#include <metal_stdlib>
using namespace metal;

struct Inst {
    float4 rect;
    float4 radii;
    float4 fill;
    float4 border;
    float4 params;
    float4 uv;
    float4 vp;
};

struct VOut {
    float4 pos [[position]];
    uint id [[flat]];
    float2 px;
};

vertex VOut demo_ui_vs(
    uint vi [[vertex_id]],
    uint ii [[instance_id]],
    constant Inst* insts [[buffer(0)]]
) {
    Inst u = insts[ii];
    float m = 1.0;
    float2 corner = float2(float(vi & 1u), float((vi >> 1u) & 1u));
    float2 px = u.rect.xy - m + (u.rect.zw + 2.0 * m) * corner;
    VOut o;
    o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
    o.id = ii;
    o.px = px;
    return o;
}

static inline float sd_rrect(float2 q, float2 halfSz, float4 radii) {
    float r = (q.x >= 0.0) ? ((q.y >= 0.0) ? radii.z : radii.y) : ((q.y >= 0.0) ? radii.w : radii.x);
    float rr = clamp(r, 0.0, min(halfSz.x, halfSz.y));
    float2 k = abs(q) - halfSz + rr;
    return length(max(k, float2(0.0))) + min(max(k.x, k.y), 0.0) - rr;
}

fragment float4 demo_ui_fs(
    VOut in [[stage_in]],
    constant Inst* insts [[buffer(0)]],
    texture2d<float> atlas [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    Inst u = insts[in.id];
    int kind = int(u.params.y + 0.5);
    if (kind == 1) {
        float2 t = (in.px - u.rect.xy) / max(u.rect.zw, float2(1e-4));
        if (any(t < 0.0) || any(t > 1.0)) {
            return float4(0.0);
        }
        float2 uv = mix(u.uv.xy, u.uv.zw, t);
        float a = atlas.sample(smp, uv, level(0.0)).r;
        return u.fill * a;
    }
    float2 halfSz = u.rect.zw * 0.5;
    float2 q = in.px - u.rect.xy - halfSz;
    float d = sd_rrect(q, halfSz, u.radii);
    float cov = clamp(0.5 - d, 0.0, 1.0);
    float4 o = u.fill * cov;
    float bw = u.params.x;
    if (bw > 0.0) {
        float inner = clamp(0.5 - (d + bw), 0.0, 1.0);
        float band = cov - inner;
        o = o * (1.0 - u.border.a * band) + u.border * band;
    }
    return o;
}
"""

final class DemoUIRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    private var atlasTex: MTLTexture
    private var atlasGen: UInt64 = 0
    private var instBuf: MTLBuffer
    private var instCap: Int

    init(device: MTLDevice, pixelFormat: MTLPixelFormat = .rgba16Float) throws {
        precondition(MemoryLayout<DemoUIInst>.stride == 112)
        self.device = device
        let lib = try device.makeLibrary(source: demoUIMetalSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "demo ui"
        pd.vertexFunction = lib.makeFunction(name: "demo_ui_vs")
        pd.fragmentFunction = lib.makeFunction(name: "demo_ui_fs")
        pd.colorAttachments[0].pixelFormat = pixelFormat
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: pd)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sd)!

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1024, height: 1024, mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        self.atlasTex = device.makeTexture(descriptor: td)!

        self.instCap = 1024
        self.instBuf = device.makeBuffer(length: self.instCap * MemoryLayout<DemoUIInst>.stride, options: .storageModeShared)!
    }

    private func syncAtlas(_ glyphAtlas: GlyphAtlas) {
        let r8 = glyphAtlas.atlas
        if atlasTex.width != r8.width || atlasTex.height != r8.height {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: r8.width, height: r8.height, mipmapped: false)
            td.usage = [.shaderRead]
            td.storageMode = .shared
            atlasTex = device.makeTexture(descriptor: td)!
            atlasGen = 0
        }
        if atlasGen != glyphAtlas.generation {
            r8.texels.withUnsafeBytes { raw in
                if let ptr = raw.baseAddress {
                    atlasTex.replace(
                        region: MTLRegionMake2D(0, 0, r8.width, r8.height),
                        mipmapLevel: 0,
                        withBytes: ptr,
                        bytesPerRow: r8.width
                    )
                }
            }
            atlasGen = glyphAtlas.generation
        }
    }

    func draw(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        clear: MTLClearColor,
        insts: [DemoUIInst],
        glyphAtlas: GlyphAtlas
    ) {
        syncAtlas(glyphAtlas)
        if insts.count > instCap {
            var nextCap = instCap
            while nextCap < insts.count { nextCap *= 2 }
            instCap = nextCap
            instBuf = device.makeBuffer(length: instCap * MemoryLayout<DemoUIInst>.stride, options: .storageModeShared)!
        }
        if !insts.isEmpty {
            _ = insts.withUnsafeBytes { raw in
                memcpy(instBuf.contents(), raw.baseAddress!, raw.count)
            }
        }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = clear
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        if !insts.isEmpty {
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(instBuf, offset: 0, index: 0)
            enc.setFragmentBuffer(instBuf, offset: 0, index: 0)
            enc.setFragmentTexture(atlasTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: insts.count)
        }
        enc.endEncoding()
    }
}
#endif

private func premul(_ c: Color) -> SIMD4<Float> {
    SIMD4<Float>(c.r * c.a, c.g * c.a, c.b * c.a, c.a)
}

private func makeInst(rect: SIMD4<Float>, radii: Float, fill: Color, border: (Color, Float)? = nil, vp: SIMD2<Float>) -> DemoUIInst {
    let (bc, bw) = border ?? (.transparent, 0)
    return DemoUIInst(
        rect: rect,
        radii: SIMD4<Float>(repeating: radii),
        fill: premul(fill),
        border: bw > 0 ? premul(bc) : .zero,
        params: SIMD4<Float>(bw, 0, 0, 1),
        uv: .zero,
        vp: SIMD4<Float>(vp.x, vp.y, 0, 0)
    )
}

final class DemoUIBuilder {
    let ts: TextSystem
    let scale: Float
    let viewportPx: SIMD2<Float>
    var base: [DemoUIInst] = []
    var text: [DemoUIInst] = []
    var prims: [Prim] = []
    var clear: Color

    init(ts: TextSystem, clear: Color, scale: Float = 2.0, viewportPx: SIMD2<Float> = SIMD2<Float>(Float(demoW), Float(demoH))) {
        self.ts = ts
        self.clear = clear
        self.scale = scale
        self.viewportPx = viewportPx
    }

    func rect(
        _ x: Float, _ y: Float, _ w: Float, _ h: Float,
        radius r: Float,
        fill: Color,
        border: (Color, Float)? = nil,
        _ build: (Prim) -> Prim = { $0 }
    ) {
        let pxRect = SIMD4<Float>(x * scale, y * scale, w * scale, h * scale)
        let scaledBorder = border.map { ($0.0, $0.1 * scale) }
        base.append(makeInst(rect: pxRect, radii: r * scale, fill: fill, border: scaledBorder, vp: viewportPx))
        let prim = Prim.fromRune(rect: pxRect, radii: SIMD4<Float>(repeating: r * scale))
            .albedo(SIMD3<Float>(fill.r, fill.g, fill.b))
        prims.append(build(prim))
    }

    func paint(_ x: Float, _ y: Float, _ w: Float, _ h: Float, radius r: Float, fill: Color) {
        let pxRect = SIMD4<Float>(x * scale, y * scale, w * scale, h * scale)
        base.append(makeInst(rect: pxRect, radii: r * scale, fill: fill, border: nil, vp: viewportPx))
    }

    @discardableResult
    func text(_ x: Float, _ y: Float, _ str: String, size: Float, weight: Float, color: Color) -> Float {
        let style = TextStyle(size: size, weight: weight, family: .systemUI, wrap: .noWrap)
        let shaped = ts.shape(text: str, style: style, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
        let ox = (x * scale).rounded()
        let oy = (y * scale).rounded()
        let fill = premul(color)
        for g in shaped.glyphs {
            text.append(DemoUIInst(
                rect: SIMD4<Float>(
                    ox + g.rect.x * scale,
                    oy + g.rect.y * scale,
                    g.rect.z * scale,
                    g.rect.w * scale
                ),
                radii: .zero,
                fill: fill,
                border: .zero,
                params: SIMD4<Float>(0, 1, 0, 1),
                uv: g.uv,
                vp: SIMD4<Float>(viewportPx.x, viewportPx.y, 0, 0)
            ))
        }
        return shaped.size.x
    }

    func lines(_ x: Float, _ y: Float, lh: Float, _ items: [String], size: Float, weight: Float, color: Color) {
        for (i, line) in items.enumerated() where !line.isEmpty {
            text(x, y + Float(i) * lh, line, size: size, weight: weight, color: color)
        }
    }

    func measure(_ str: String, size: Float, weight: Float) -> Float {
        ts.measure(str, style: TextStyle(size: size, weight: weight, family: .systemUI, wrap: .noWrap), maxWidth: nil, pixelScale: scale).x
    }
}

struct DemoFrame {
    var prims: [Prim]
    var base: [DemoUIInst]
    var text: [DemoUIInst]
    var clear: Color
    var lights: [Light]
    var settings: LightSettings
}

protocol LightDemo {
    var name: String { get }
    var seconds: Float { get }
    var still: Float { get }
    func frame(ts: TextSystem, t: Float, scale: Float) -> DemoFrame
}

extension LightDemo {
    var seconds: Float { 4.0 }
}

private func loopPath(_ pts: [SIMD2<Float>], u: Float) -> SIMD2<Float> {
    let n = pts.count
    let rem = u - floorf(u)
    let x = rem * Float(n)
    let i = Int(floorf(x))
    let f = x - Float(i)
    func pt(_ k: Int) -> SIMD2<Float> {
        let idx = ((i + k) % n + n) % n
        return pts[idx]
    }
    let p0 = pt(-1), p1 = pt(0), p2 = pt(1), p3 = pt(2)
    func cr(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
        0.5 * ((2 * b) + (-a + c) * f + (2 * a - 5 * b + 4 * c - d) * f * f + (-a + 3 * b - 3 * c + d) * f * f * f)
    }
    return SIMD2<Float>(cr(p0.x, p1.x, p2.x, p3.x), cr(p0.y, p1.y, p2.y, p3.y))
}

private final class DragTrack {
    var x: SpringTrack
    var y: SpringTrack
    let stops: [(Float, SIMD2<Float>)]
    var next: Int = 1
    let spring: Spring

    init(stops: [(Float, SIMD2<Float>)], spring: Spring) {
        self.stops = stops
        self.spring = spring
        self.x = SpringTrack.at(stops[0].1.x)
        self.y = SpringTrack.at(stops[0].1.y)
    }

    func at(_ t: Float) -> SIMD2<Float> {
        while next < stops.count && stops[next].0 <= t {
            let (ts, p) = stops[next]
            x.retarget(at: Double(ts), target: p.x, spring: spring)
            y.retarget(at: Double(ts), target: p.y, spring: spring)
            next += 1
        }
        return SIMD2<Float>(x.value(at: Double(t)), y.value(at: Double(t)))
    }
}

final class ChatDemo: LightDemo {
    let name = "chat"
    let still: Float = 1.6
    private let drag = DragTrack(
        stops: [
            (0.0, SIMD2<Float>(1085, 250)),
            (0.2, SIMD2<Float>(1060, 268)),
            (0.9, SIMD2<Float>(928, 382)),
            (1.6, SIMD2<Float>(1100, 530)),
            (2.35, SIMD2<Float>(905, 657)),
            (3.0, SIMD2<Float>(560, 658)),
            (3.55, SIMD2<Float>(1085, 250)),
        ],
        spring: Spring(duration: 0.85, bounce: 0.0)
    )

    func frame(ts: TextSystem, t: Float, scale: Float) -> DemoFrame {
        chatScene(ts: ts, t: t, p: drag.at(t), scale: scale)
    }
}

func chatScene(ts: TextSystem, t: Float, p: SIMD2<Float>, scale: Float) -> DemoFrame {
    let bg = oklch(0.17, 0.006, 265)
    let ui = DemoUIBuilder(ts: ts, clear: bg, scale: scale)
    let side = oklch(0.195, 0.006, 265)
    let txt = oklch(0.93, 0.004, 265)
    let txt2 = oklch(0.66, 0.01, 265)
    let txt3 = oklch(0.52, 0.01, 265)
    let hair = oklcha(1.0, 0.0, 0.0, 0.06)
    let card = oklch(0.235, 0.007, 265)
    let user = oklch(0.3, 0.045, 258)
    let code = oklch(0.195, 0.008, 265)
    let accent = oklch(0.72, 0.15, 255)

    ui.rect(0, 0, 268, 800, radius: 0, fill: side)
    ui.paint(268, 0, 1, 800, radius: 0, fill: hair)
    ui.text(24, 22, "OpenCode", size: 15, weight: 600, color: txt)
    ui.rect(20, 58, 228, 34, radius: 9, fill: card, border: (hair, 1)) {
        $0.raised(3 * scale).bevel(width: 3 * scale, height: 1.2 * scale).gloss(0.5, roughness: 0.45)
    }
    ui.text(36, 66, "+  New session", size: 13, weight: 500, color: txt)
    ui.text(24, 116, "TODAY", size: 11, weight: 600, color: txt3)
    let sessions = [
        "rune-light: lighting for UIs",
        "Scroll momentum on iOS",
        "Theme tokens codegen",
        "Hex settings screen",
        "Slug text spike",
        "Radiance cascades notes",
        "Motion blur from tracks",
    ]
    for (i, s) in sessions.enumerated() {
        let y = 138 + Float(i) * 36
        if i == 0 {
            ui.rect(14, y - 7, 240, 32, radius: 8, fill: oklcha(1, 0, 0, 0.06))
        }
        ui.text(26, y, s, size: 13, weight: i == 0 ? 500 : 400, color: i == 0 ? txt : txt2)
    }

    ui.text(300, 22, "rune-light: lighting for UIs", size: 14, weight: 600, color: txt)
    let chip = "claude-opus-5.5"
    let cw = ui.measure(chip, size: 12, weight: 500)
    ui.rect(1240 - cw - 24, 16, cw + 24, 28, radius: 14, fill: card, border: (hair, 1)) {
        $0.raised(2 * scale).bevel(width: 4 * scale, height: 1 * scale).gloss(0.5, roughness: 0.4)
    }
    ui.text(1240 - cw - 12, 22, chip, size: 12, weight: 500, color: txt2)
    ui.paint(269, 60, 1011, 1, radius: 0, fill: hair)

    let raise: (Prim) -> Prim = { $0.raised(7 * scale).bevel(width: 6 * scale, height: 2 * scale).gloss(0.55, roughness: 0.42) }
    ui.rect(800, 88, 440, 68, radius: 16, fill: user, border: (oklcha(1, 0, 0, 0.08), 1), raise)
    ui.lines(818, 101, lh: 21, ["what if lighting effects. like you could put a light and", "it would raytrace around the ui elements…"], size: 14, weight: 400, color: txt)

    ui.rect(300, 182, 600, 152, radius: 16, fill: card, border: (hair, 1), raise)
    ui.lines(322, 198, lh: 21, [
        "Every Rune element is an analytic rounded rect, so the frame is",
        "already an exact distance field. A light can sphere-trace soft",
        "shadows straight through it: contact-hard near each bubble,",
        "wide and soft where the light is far.",
    ], size: 14, weight: 400, color: txt)
    let chipXs: [Float] = [0, 140, 330]
    for (i, chipt) in ["Read shader.wgsl", "Edit rune-light/src/lib.rs", "Run bench"].enumerated() {
        let x = 322 + chipXs[i]
        let w = ui.measure(chipt, size: 12, weight: 500) + 22
        ui.rect(x, 292, w, 26, radius: 13, fill: oklch(0.27, 0.008, 265), border: (hair, 1)) {
            $0.on(7 * scale).raised(2.5 * scale).bevel(width: 4 * scale, height: 1 * scale).gloss(0.4, roughness: 0.4)
        }
        ui.text(x + 11, 297, chipt, size: 12, weight: 500, color: txt2)
    }

    ui.rect(960, 360, 280, 44, radius: 16, fill: user, border: (oklcha(1, 0, 0, 0.08), 1), raise)
    ui.lines(980, 372, lh: 21, ["MAKE THIS SOOO GOOOD"], size: 14, weight: 400, color: txt)

    ui.rect(300, 430, 640, 196, radius: 16, fill: card, border: (hair, 1), raise)
    ui.lines(322, 446, lh: 21, ["Here's the API: lights are springs like everything else."], size: 14, weight: 400, color: txt)
    ui.rect(318, 480, 604, 126, radius: 10, fill: code, border: (hair, 1)) {
        $0.on(7 * scale).gloss(0.2, roughness: 0.5)
    }
    let mono = oklch(0.8, 0.06, 200)
    ui.lines(336, 494, lh: 20, [
        "let lamp = Light::point(x, y, 60.0)",
        "    .color(WARM).intensity(1.6).radius(10.0);",
        "",
        "lights.render(&scene, &[lamp], target);",
        "",
    ], size: 13, weight: 400, color: mono)

    ui.rect(300, 690, 940, 78, radius: 18, fill: card, border: (oklcha(1, 0, 0, 0.09), 1)) {
        $0.raised(10 * scale).bevel(width: 7 * scale, height: 2.5 * scale).gloss(0.6, roughness: 0.38)
    }
    ui.text(322, 708, "Ask anything…", size: 14, weight: 400, color: txt3)
    ui.rect(1192, 724, 32, 32, radius: 16, fill: accent) {
        $0.on(10 * scale).raised(4 * scale).bevel(width: 10 * scale, height: 3 * scale).gloss(0.8, roughness: 0.3)
    }
    ui.paint(1203, 739, 10, 2, radius: 1, fill: oklch(0.2, 0.02, 255))

    let lamp = Light.point(p.x * scale, p.y * scale, 40 * scale)
        .color(demoLinear(1.0, 0.78, 0.55))
        .intensity(2.6)
        .radius(11 * scale)
        .range(1100 * scale)
        .bulb(0.75)
        .specular(1.2)
    let fill = Light.point(-300 * scale, -200 * scale, 900 * scale)
        .color(demoLinear(0.55, 0.65, 1.0))
        .intensity(0.35)
        .radius(220 * scale)
        .range(6000 * scale)
        .specular(0.4)
    let s = LightSettings(
        ambient: SIMD3<Float>(0.62, 0.63, 0.7),
        gi: nil,
        contactAO: 0.45,
        rim: 0.9,
        albedoFloor: 0.07,
        time: t
    )
    return DemoFrame(prims: ui.prims, base: ui.base, text: ui.text, clear: ui.clear, lights: [lamp, fill], settings: s)
}

let ctlToggle0 = 0
let ctlDot0 = 5
let ctlSlider = 10
let ctlButton0 = 11
let ctlCount = 18
let dotHues: [Float] = [255, 300, 350, 40, 150]

func accentFor(_ hue: Float) -> Color {
    oklch(0.7, 0.15, hue)
}

struct DemoPanel {
    var toggles: [Float] = [1, 0, 1, 0, 1]
    var accent: Color = accentFor(255)
    var selected: Int = 0
    var ring: Float = 0
    var volume: Float = 82.0 / 130.0
    var hover: [Float] = [Float](repeating: 0, count: ctlCount)
    var press: [Float] = [Float](repeating: 0, count: ctlCount)

    func lift(_ id: Int) -> Float {
        (1.0 + 0.45 * hover[id]) * (1.0 - 0.92 * min(max(press[id], 0), 1.2))
    }
}

struct HitRegion {
    var id: Int
    var rect: SIMD4<Float>
}

private func mixColor(_ a: Color, _ b: Color, _ k0: Float) -> Color {
    let k = min(max(k0, 0), 1)
    return Color(r: a.r + (b.r - a.r) * k, g: a.g + (b.g - a.g) * k, b: a.b + (b.b - a.b) * k, a: a.a + (b.a - a.a) * k)
}

private func settingsPanel(_ ui: DemoUIBuilder, card: Color, txt: Color, txt2: Color, hair: Color, st: DemoPanel, scale: Float) -> [HitRegion] {
    let accent = st.accent
    var hits: [HitRegion] = []
    let raiseCard: (Prim) -> Prim = { $0.raised(4 * scale).bevel(width: 5 * scale, height: 1.5 * scale).gloss(0.45, roughness: 0.45) }
    let top = 4 * scale
    ui.text(160, 70, "Settings", size: 24, weight: 600, color: txt)
    ui.text(160, 106, "Appearance, sound and shortcuts", size: 13, weight: 400, color: txt2)

    let rows: [(String, String, Int)] = [
        ("Appearance", "Dark", 2),
        ("Accent colour", "", 3),
        ("Reduce motion", "", 1),
        ("Sound effects", "", 0),
        ("Notification volume", "", 4),
        ("Push to talk", "⌥ Space", 2),
        ("Auto-update", "", 1),
        ("Send crash reports", "", 0),
        ("Launch at login", "", 1),
    ]
    var toggle = 0
    var button = 0
    let y: Float = 150
    for gi in 0..<3 {
        let group = Array(rows[(gi * 3)..<(gi * 3 + 3)])
        let x = 160 + Float(gi) * 330
        let h = Float(group.count) * 56
        ui.rect(x, y, 310, h, radius: 14, fill: card, border: (hair, 1), raiseCard)
        for (ri, (label, value, kind)) in group.enumerated() {
            let ry = y + Float(ri) * 56
            if ri > 0 {
                ui.paint(x + 16, ry, 278, 1, radius: 0, fill: hair)
            }
            ui.text(x + 18, ry + 19, label, size: 13, weight: 500, color: txt)
            let rx = x + 310 - 18
            switch kind {
            case 0, 1:
                let id = ctlToggle0 + toggle
                toggle += 1
                let k = st.toggles[id - ctlToggle0]
                let m = st.lift(id)
                let track = mixColor(oklch(0.33, 0.006, 265), accent, k)
                ui.rect(rx - 42, ry + 16, 42, 24, radius: 12, fill: track) { $0.on(top).gloss(0.4, roughness: 0.4) }
                let kx = rx - 40 + 18 * k
                ui.rect(kx, ry + 18, 20, 20, radius: 10, fill: oklch(0.96, 0, 0)) {
                    $0.on(top).raised(5 * scale * m).bevel(width: 10 * scale, height: 4 * scale * m).gloss(0.7, roughness: 0.3)
                }
                hits.append(HitRegion(id: id, rect: SIMD4<Float>(rx - 42, ry + 16, 42, 24)))
            case 2:
                let id = ctlButton0 + button
                button += 1
                let m = st.lift(id)
                let w = ui.measure(value, size: 12, weight: 500) + 20
                ui.rect(rx - w, ry + 14, w, 28, radius: 8, fill: oklch(0.3, 0.006, 265), border: (hair, 1)) {
                    $0.on(top).raised(3 * scale * m).bevel(width: 4 * scale, height: 1.2 * scale * m).gloss(0.5, roughness: 0.4)
                }
                ui.text(rx - w + 10, ry + 20, value, size: 12, weight: 500, color: txt)
                hits.append(HitRegion(id: id, rect: SIMD4<Float>(rx - w, ry + 14, w, 28)))
            case 3:
                for (k, hVal) in dotHues.enumerated() {
                    let id = ctlDot0 + k
                    let m = st.lift(id)
                    let c = oklch(0.68, 0.15, hVal)
                    let cx = rx - 18 - Float(k) * 26
                    if k == st.selected && st.ring > 0 {
                        let o: Float = 3.0
                        let ring = oklcha(0.95, 0, 0, 0.8 * st.ring)
                        ui.base.append(makeInst(
                            rect: SIMD4<Float>((cx - o) * scale, (ry + 19 - o) * scale, (18 + 2 * o) * scale, (18 + 2 * o) * scale),
                            radii: (9 + o) * scale,
                            fill: .transparent,
                            border: (ring, 1.5 * scale),
                            vp: ui.viewportPx
                        ))
                    }
                    ui.rect(cx, ry + 19, 18, 18, radius: 9, fill: c) {
                        $0.on(top).raised(3.5 * scale * m).bevel(width: 9 * scale, height: 3 * scale * m).gloss(0.7, roughness: 0.3)
                    }
                    hits.append(HitRegion(id: id, rect: SIMD4<Float>(cx - 4, ry + 15, 26, 26)))
                }
            default:
                let m = st.lift(ctlSlider)
                let v = min(max(st.volume, 0), 1)
                ui.rect(rx - 130, ry + 26, 130, 4, radius: 2, fill: oklch(0.33, 0.006, 265)) { $0.on(top) }
                if v > 0 {
                    ui.rect(rx - 130, ry + 26, 130 * v, 4, radius: 2, fill: accent) { $0.on(top) }
                }
                ui.rect(rx - 140 + 130 * v, ry + 18, 20, 20, radius: 10, fill: oklch(0.96, 0, 0)) {
                    $0.on(top).raised(6 * scale * m).bevel(width: 10 * scale, height: 4 * scale * m).gloss(0.7, roughness: 0.3)
                }
                hits.append(HitRegion(id: ctlSlider, rect: SIMD4<Float>(rx - 130, ry + 12, 130, 32)))
            }
        }
    }

    let by: Float = 340
    ui.rect(160, by, 970, 150, radius: 14, fill: card, border: (hair, 1), raiseCard)
    ui.text(180, by + 20, "Keyboard shortcuts", size: 15, weight: 600, color: txt)
    ui.text(180, by + 46, "Press a key combination to record a new shortcut.", size: 13, weight: 400, color: txt2)
    for (i, k) in ["⌘", "⇧", "K"].enumerated() {
        let id = ctlButton0 + 2 + i
        let m = st.lift(id)
        ui.rect(180 + Float(i) * 52, by + 82, 44, 44, radius: 10, fill: oklch(0.3, 0.006, 265), border: (hair, 1)) {
            $0.on(top).raised(6 * scale * m).bevel(width: 7 * scale, height: 2.5 * scale * m).gloss(0.6, roughness: 0.35)
        }
        ui.text(195 + Float(i) * 52, by + 94, k, size: 15, weight: 600, color: txt)
        hits.append(HitRegion(id: id, rect: SIMD4<Float>(180 + Float(i) * 52, by + 82, 44, 44)))
    }
    let m6 = st.lift(ctlButton0 + 6)
    ui.rect(940, by + 90, 170, 36, radius: 10, fill: accent) {
        $0.on(top).raised(5 * scale * m6).bevel(width: 6 * scale, height: 2 * scale * m6).gloss(0.7, roughness: 0.3)
    }
    ui.text(975, by + 99, "Record shortcut", size: 13, weight: 600, color: oklch(0.18, 0.03, 255))
    hits.append(HitRegion(id: ctlButton0 + 6, rect: SIMD4<Float>(940, by + 90, 170, 36)))

    let m5 = st.lift(ctlButton0 + 5)
    ui.rect(780, by + 90, 140, 36, radius: 10, fill: oklch(0.3, 0.006, 265), border: (hair, 1)) {
        $0.on(top).raised(5 * scale * m5).bevel(width: 6 * scale, height: 2 * scale * m5).gloss(0.6, roughness: 0.35)
    }
    ui.text(828, by + 99, "Reset", size: 13, weight: 600, color: txt)
    hits.append(HitRegion(id: ctlButton0 + 5, rect: SIMD4<Float>(780, by + 90, 140, 36)))

    let tileNames = ["Microphone", "Speakers", "Camera", "Display", "Battery"]
    let tileSubs = ["MacBook Pro", "Studio Display", "FaceTime HD", "Built-in", "92 %"]
    let tileFills: [Float] = [0.7, 0.45, 0.0, 0.85, 0.92]
    for i in 0..<5 {
        let x = 160 + Float(i) * 198
        ui.rect(x, 520, 180, 120, radius: 14, fill: card, border: (hair, 1), raiseCard)
        ui.text(x + 18, 538, tileNames[i], size: 13, weight: 600, color: txt)
        ui.text(x + 18, 560, tileSubs[i], size: 12, weight: 400, color: txt2)
        ui.rect(x + 18, 600, 144, 18, radius: 9, fill: oklch(0.27, 0.006, 265)) { $0.on(top) }
        if tileFills[i] > 0 {
            ui.rect(x + 18, 600, 144 * tileFills[i], 18, radius: 9, fill: accent) {
                $0.on(top).raised(2 * scale).bevel(width: 9 * scale, height: 2 * scale).gloss(0.6, roughness: 0.3)
            }
        }
    }
    return hits
}

func flashlightScene(ts: TextSystem, t: Float, p: SIMD2<Float>, panel: DemoPanel, overhead: Bool, scale: Float) -> (DemoFrame, [HitRegion]) {
    let bg = oklch(0.16, 0.005, 265)
    let ui = DemoUIBuilder(ts: ts, clear: bg, scale: scale)
    let hits = settingsPanel(
        ui,
        card: oklch(0.225, 0.006, 265),
        txt: oklch(0.94, 0.003, 265),
        txt2: oklch(0.66, 0.01, 265),
        hair: oklcha(1, 0, 0, 0.06),
        st: panel,
        scale: scale
    )
    let lp = overhead ? SIMD3<Float>(p.x, p.y, 260) : SIMD3<Float>(p.x + 80, p.y + 130, 260)
    let axis = SIMD3<Float>(p.x - lp.x, p.y - lp.y, -lp.z)
    let torch = Light.point(lp.x * scale, lp.y * scale, lp.z * scale)
        .color(demoLinear(1.0, 0.95, 0.88))
        .intensity(7.0)
        .radius(9 * scale)
        .range(1800 * scale)
        .spot(axis: axis, halfAngle: 0.58)
        .specular(1.4)
    let s = LightSettings(
        ambient: SIMD3<Float>(0.07, 0.075, 0.09),
        text: TextPolicy(floor: 0.32, ceiling: 1.3, lit: 1.0, specular: 0.1),
        gi: nil,
        backgroundGloss: 0.5,
        contactAO: 0.3,
        rim: 1.0,
        albedoFloor: 0.04,
        time: t
    )
    return (DemoFrame(prims: ui.prims, base: ui.base, text: ui.text, clear: ui.clear, lights: [torch], settings: s), hits)
}

final class FlashlightDemo: LightDemo {
    let name = "flashlight"
    let still: Float = 1.15

    func frame(ts: TextSystem, t: Float, scale: Float) -> DemoFrame {
        let path: [SIMD2<Float>] = [
            SIMD2<Float>(300, 230),
            SIMD2<Float>(700, 180),
            SIMD2<Float>(1020, 300),
            SIMD2<Float>(860, 470),
            SIMD2<Float>(560, 600),
            SIMD2<Float>(260, 520),
        ]
        let p = loopPath(path, u: t / 4.0 + 0.02)
        return flashlightScene(ts: ts, t: t, p: p, panel: DemoPanel(), overhead: false, scale: scale).0
    }
}

final class EmissiveDemo: LightDemo {
    let name = "emissive"
    let still: Float = 2.4
    private var breath = SpringTrack.at(0.8)
    private var flip: Float = 0.0
    private var up: Bool = false

    func frame(ts: TextSystem, t: Float, scale: Float) -> DemoFrame {
        while t >= flip {
            up.toggle()
            breath.retarget(at: Double(flip), target: up ? 1.0 : 0.55, spring: Spring(duration: 0.85, bounce: 0.0))
            flip += 1.1
        }
        let b = breath.value(at: Double(t))
        let bg = oklch(0.15, 0.006, 265)
        let ui = DemoUIBuilder(ts: ts, clear: bg, scale: scale)
        let card = oklch(0.23, 0.006, 265)
        let txt = oklch(0.94, 0.003, 265)
        let txt2 = oklch(0.64, 0.01, 265)
        let hair = oklcha(1, 0, 0, 0.06)
        let raise: (Prim) -> Prim = { $0.raised(6 * scale).bevel(width: 6 * scale, height: 2 * scale).gloss(0.5, roughness: 0.42) }

        ui.text(140, 64, "Voice memo", size: 24, weight: 600, color: txt)
        ui.text(140, 100, "Recording · Studio Display microphone", size: 13, weight: 400, color: txt2)

        for (i, (title, sub)) in [("Transcript", "Live, 2 speakers"), ("Markers", "3 added"), ("Noise", "Voice isolation on")].enumerated() {
            let y = 150 + Float(i) * 128
            ui.rect(140, y, 300, 108, radius: 16, fill: card, border: (hair, 1), raise)
            ui.text(162, y + 20, title, size: 14, weight: 600, color: txt)
            ui.text(162, y + 44, sub, size: 13, weight: 400, color: txt2)
        }

        ui.rect(470, 150, 400, 364, radius: 20, fill: card, border: (hair, 1), raise)
        ui.text(494, 172, "00:42.18", size: 34, weight: 600, color: txt)
        ui.text(494, 220, "Recording", size: 13, weight: 500, color: oklch(0.75, 0.12, 25))
        for k in 0..<40 {
            let kf = Float(k)
            let h = 8 + 46 * abs(0.5 + 0.5 * sinf(kf * 0.7) * cosf(kf * 0.23 + 1.0))
            ui.rect(494 + kf * 8.8, 290 - h * 0.5, 4.6, h, radius: 2.3, fill: oklch(0.5, 0.01, 265)) {
                $0.on(12).raised(2 * scale)
            }
        }
        let red = oklch(0.66, 0.2, 25)
        let glow = 7.0 * b
        ui.rect(620, 370, 100, 100, radius: 50, fill: oklch(0.27, 0.008, 265), border: (hair, 1)) {
            $0.on(12).bevel(width: 16 * scale, height: 4 * scale).gloss(0.6, roughness: 0.35)
        }
        ui.rect(640, 390, 60, 60, radius: 30, fill: red) {
            $0.on(12).emissive(SIMD3<Float>(red.r * glow, red.g * glow, red.b * glow))
        }

        let prog = 0.25 + 0.5 * min(t / 4.0, 1.0)
        let cyan = oklch(0.78, 0.13, 210)
        ui.rect(140, 560, 730, 10, radius: 5, fill: oklch(0.24, 0.006, 265))
        let g2 = 1.9 * (0.85 + 0.15 * b)
        ui.rect(140, 560, 730 * prog, 10, radius: 5, fill: cyan) {
            $0.emissive(SIMD3<Float>(cyan.r * g2, cyan.g * g2, cyan.b * g2))
        }
        ui.text(140, 584, "Uploading to OpenCode · 3 of 5 files", size: 12, weight: 500, color: txt2)

        let green = oklch(0.78, 0.17, 150)
        for (i, (title, sub)) in [("Agent finished", "rune-light demos rendered"), ("Build passed", "ci · 1m 12s"), ("Review", "Argon: no blockers")].enumerated() {
            let y = 150 + Float(i) * 128
            ui.rect(900, y, 300, 108, radius: 16, fill: card, border: (hair, 1), raise)
            ui.text(940, y + 20, title, size: 14, weight: 600, color: txt)
            ui.text(940, y + 44, sub, size: 13, weight: 400, color: txt2)
            let gd: Float = (i == 0) ? 2.2 * (0.6 + 0.4 * b) : 0.0
            let c = (i == 0) ? green : oklch(0.45, 0.01, 265)
            ui.rect(918, y + 24, 10, 10, radius: 5, fill: c) {
                $0.on(12).emissive(SIMD3<Float>(c.r * gd, c.g * gd, c.b * gd))
            }
        }
        let dockLabels = ["Pause", "Marker", "Trim", "Share", "Export", "Delete"]
        for i in 0..<6 {
            let x = 140 + Float(i) * 178
            ui.rect(x, 640, 160, 90, radius: 16, fill: card, border: (hair, 1), raise)
            ui.text(x + 18, 660, dockLabels[i], size: 13, weight: 600, color: txt)
        }

        let s = LightSettings(
            ambient: SIMD3<Float>(0.3, 0.31, 0.35),
            gi: GIParams(strength: 1.0, air: 0.09, bounce: 0.0, absorption: 0.24),
            contactAO: 0.4,
            rim: 0.6,
            time: t
        )
        return DemoFrame(prims: ui.prims, base: ui.base, text: ui.text, clear: ui.clear, lights: [], settings: s)
    }
}

final class RaisedDemo: LightDemo {
    let name = "raised"
    let still: Float = 1.4

    func frame(ts: TextSystem, t: Float, scale: Float) -> DemoFrame {
        let bg = oklch(0.2, 0.004, 265)
        let ui = DemoUIBuilder(ts: ts, clear: bg, scale: scale)
        let txt = oklch(0.92, 0.003, 265)
        let txt2 = oklch(0.62, 0.008, 265)
        let body = oklch(0.255, 0.004, 265)
        let key = oklch(0.29, 0.004, 265)

        ui.rect(120, 90, 1040, 620, radius: 36, fill: body, border: (oklcha(1, 0, 0, 0.05), 1)) {
            $0.raised(10 * scale).bevel(width: 22 * scale, height: 7 * scale).gloss(0.7, roughness: 0.32)
        }
        ui.text(170, 130, "OP-1 Field · Control surface", size: 15, weight: 600, color: txt)
        ui.text(170, 156, "Bevels from the SDF catch the light", size: 12, weight: 400, color: txt2)

        let hues: [Float] = [255, 150, 60, 25]
        for i in 0..<4 {
            let cx = 200 + Float(i) * 140
            ui.rect(cx - 48, 210, 96, 96, radius: 48, fill: key) {
                $0.floating(bottom: 10 * scale, top: 22 * scale).bevel(width: 30 * scale, height: 10 * scale).gloss(0.9, roughness: 0.26)
            }
            ui.rect(cx - 5, 222, 10, 10, radius: 5, fill: oklch(0.7, 0.14, hues[i]))
        }

        ui.rect(780, 200, 330, 200, radius: 18, fill: oklch(0.14, 0.01, 265)) { $0.gloss(1.0, roughness: 0.18) }
        ui.text(806, 226, "128 BPM", size: 28, weight: 600, color: oklch(0.85, 0.12, 150))
        ui.text(806, 270, "Pattern A · bar 12", size: 13, weight: 400, color: oklch(0.6, 0.06, 150))

        let notes = ["C", "D", "E", "F", "G", "A", "B", "C", "D", "E", "F", "G"]
        for r in 0..<2 {
            for i in 0..<12 {
                let x = 170 + Float(i) * 78
                let y = 450 + Float(r) * 110
                let isAcc = (r == 0 && (i == 2 || i == 7)) || (r == 1 && i == 10)
                let c = isAcc ? oklch(0.62, 0.17, 35) : key
                ui.rect(x, y, 68, 92, radius: 14, fill: c) {
                    $0.floating(bottom: 10 * scale, top: 18 * scale).bevel(width: 12 * scale, height: 4.5 * scale).gloss(0.85, roughness: 0.28)
                }
                ui.text(x + 12, y + 12, notes[i], size: 12, weight: 600, color: isAcc ? oklch(0.2, 0.03, 35) : txt2)
            }
        }

        let u = min(max(t / seconds, 0), 1)
        let e = u * u * (3 - 2 * u)
        let lx = 40 + e * 1200
        let ly = 560 - 300 * (1 - powf(2 * e - 1, 2))
        let keyL = Light.point(lx * scale, ly * scale, 150 * scale)
            .color(demoLinear(1.0, 0.93, 0.85)).intensity(3.4).radius(26 * scale).range(2200 * scale).specular(2.4)
        let fill = Light.point(1400 * scale, 900 * scale, 700 * scale)
            .color(demoLinear(0.5, 0.62, 1.0)).intensity(0.4).radius(200 * scale).range(5000 * scale).specular(0.6)
        let s = LightSettings(ambient: SIMD3<Float>(0.3, 0.31, 0.34), contactAO: 0.5, rim: 1.1, time: t)
        return DemoFrame(prims: ui.prims, base: ui.base, text: ui.text, clear: ui.clear, lights: [keyL, fill], settings: s)
    }
}

final class GodRaysDemo: LightDemo {
    let name = "godrays"
    let still: Float = 1.0

    func frame(ts: TextSystem, t: Float, scale: Float) -> DemoFrame {
        let bg = oklch(0.11, 0.014, 265)
        let ui = DemoUIBuilder(ts: ts, clear: bg, scale: scale)
        let card = oklch(0.21, 0.008, 265)
        let txt = oklch(0.93, 0.003, 265)
        let txt2 = oklch(0.6, 0.01, 265)
        let hair = oklcha(1, 0, 0, 0.06)
        let names = [
            "Inbox", "Calendar", "Notes", "Music", "Photos", "Maps", "Files", "Terminal",
            "Mail", "Weather", "Clock", "Books", "Stocks", "Podcasts", "Home", "Wallet",
            "Health", "Camera", "Code", "Fleet", "Chat", "Voice", "Launcher", "Rune",
        ]
        let cols = 8, rows = 3
        let cw: Float = 124, ch: Float = 124, gx: Float = 28, gy: Float = 28
        let x0 = (1280 - (Float(cols) * cw + Float(cols - 1) * gx)) * 0.5
        let y0: Float = 290
        for r in 0..<rows {
            for c in 0..<cols {
                let x = x0 + Float(c) * (cw + gx)
                let y = y0 + Float(r) * (ch + gy)
                let i = r * cols + c
                ui.rect(x, y, cw, ch, radius: 24, fill: card, border: (hair, 1)) {
                    $0.raised(14 * scale).bevel(width: 8 * scale, height: 2.5 * scale).gloss(0.5, roughness: 0.4)
                }
                let hue = Float((i * 47) % 360)
                ui.rect(x + 20, y + 20, 40, 40, radius: 12, fill: oklch(0.62, 0.12, hue))
                ui.text(x + 20, y + 84, names[i], size: 13, weight: 600, color: txt)
            }
        }
        ui.text(x0, 120, "Good evening", size: 30, weight: 600, color: txt)
        ui.text(x0, 164, "24 apps · light from behind the grid", size: 14, weight: 400, color: txt2)

        let u = min(max(t / seconds, 0), 1)
        let e = u * u * (3 - 2 * u)
        let lx = 488 + e * 304
        let sun = Light.point(lx * scale, 428 * scale, 4 * scale)
            .color(demoLinear(1.0, 0.8, 0.55))
            .intensity(1.6)
            .radius(12 * scale)
            .range(3000 * scale)
            .shafts(1.5)
            .softness(2.2)
        let s = LightSettings(
            ambient: SIMD3<Float>(0.5, 0.5, 0.58),
            contactAO: 0.35,
            rim: 0.8,
            shaftsOver: 0.12,
            time: t
        )
        return DemoFrame(prims: ui.prims, base: ui.base, text: ui.text, clear: ui.clear, lights: [sun], settings: s)
    }
}

func makeAllDemos() -> [any LightDemo] {
    [ChatDemo(), FlashlightDemo(), EmissiveDemo(), RaisedDemo(), GodRaysDemo()]
}
