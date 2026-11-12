import Foundation
#if canImport(Metal)
import Metal
#endif
import Rune
import RuneFX

enum ShowreelGfx {
    static let colors: [UInt32] = [
        0xffffff, 0x4f8dff, 0x22d3ee, 0x7c5cff, 0x34d399, 0xffb547, 0xff5ca8, 0xff4d4d,
        0xff7a1a, 0xf1ece1, 0x2e3036, 0xe8552b, 0x3d6bff, 0x54b3fd,
    ]

    static func rgb(_ index: Int) -> Rgb {
        let clamped = max(0, min(index, colors.count - 1))
        return RuneFX.rgb(colors[clamped])
    }

    static func chrome(variant: Int = 0, border: Float = 0, flowMul: Float = 1.0, anchorElement: Bool = false) -> Fx {
        var p: LiquidMetalParams
        switch variant {
        case 1: p = .gold()
        case 2: p = .rose()
        case 3: p = .gunmetal()
        case 4:
            p = .chrome()
            p.light = RuneFX.rgb(0xd6e8ff)
            p.iridescence = 0.3
            p.scale = 240.0
            p.bevel = 3.5
            p.dome = 0.2
            p.contrast = 1.15
        case 5:
            p = .chrome()
            p.scale = 360.0
            p.flow = 0.5
            p.speed = 0.6
            p.dome = 0.8
            p.contrast = 0.85
            p.bevel = 12.0
            p.angle = 0.45
        default:
            p = .chrome()
        }
        if flowMul > 0 { p.flow *= flowMul }
        if anchorElement { p.anchor = .element }
        let fp = border > 0 ? FillParams(.liquidMetal(p)).border(border) : FillParams(.liquidMetal(p))
        return .fill(fp)
    }

    static func mesh(palette: Int, speed: Float = 0, drift: Float = 0) -> Fx {
        var p: MeshGradientParams
        switch palette {
        case 1: p = .lagoon()
        case 2: p = .orchid()
        case 3: p = .graphite()
        case 4:
            p = .dusk()
            p.colors = Stops.hex([0x0d1b4c, 0x3d6bff, 0x9b5cff, 0x22d3ee, 0x101030])
        case 5:
            p = .dusk()
            p.colors = Stops.hex([0x2a0a12, 0xff4d4d, 0xffb547, 0x7a1640, 0xff7a1a])
        case 6:
            p = .dusk()
            p.colors = Stops.hex([0x062a24, 0x34d399, 0xd9f99d, 0x0f766e])
        case 7:
            p = .dusk()
            p.colors = Stops.hex([0x1a1033, 0xff5ca8, 0x7c5cff, 0xffd1e8, 0x2b1b5a])
        default:
            p = .dusk()
        }
        if speed > 0 { p.speed = speed }
        if drift > 0 { p.drift = drift }
        return .fill(FillParams(.meshGradient(p)))
    }

    static func fluted(rib: Float = 18.0, refraction: Float = 16.0, frost: Float = 0.12, dispersion: Float = 0.3) -> Fx {
        var p = FlutedGlassParams.reeded()
        p.rib = rib
        p.refraction = refraction
        p.frost = frost
        p.dispersion = dispersion
        p.highlight = 0.55
        return .fill(FillParams(.flutedGlass(p)))
    }

    static func fire(height: Float, intensity: Float, style: FireStyle = .top, smoke: Float = 0.6) -> Fx {
        var p = FireParams()
        p.style = style
        p.height = height
        p.intensity = intensity
        p.smoke = smoke
        p.embers = 24
        p.scale = 26.0
        return .fire(p)
    }

    static func electric(intensity: Float, amplitude: Float = 0, charged: Bool = false, colorIndex: Int = 13) -> Fx {
        var p = charged ? ElectricParams.charged() : ElectricParams()
        p.intensity = intensity
        if amplitude > 0 { p.amplitude = amplitude }
        p.color = rgb(colorIndex)
        return .electric(p)
    }

    static func glow(style: GlowStyle = .soft, colorIndex: Int, intensity: Float, radius: Float = 14.0) -> Fx {
        var p = GlowParams()
        p.style = style
        p.color = rgb(colorIndex)
        p.intensity = intensity
        p.radius = radius > 0 ? radius : 14.0
        p.auraSpeed = 0.35
        return .glow(p)
    }

    static func sparkles(burst: Float?, count: UInt32, size: Float, colorIndex: Int) -> Fx {
        var p = SparkleParams()
        p.burst = burst
        p.count = count
        p.size = size
        p.color = rgb(colorIndex)
        p.margin = 26.0
        return .sparkles(p)
    }

    static func shock(at: SIMD2<Float>, t0: Float, amount: Float = 22.0) -> Fx {
        .distort(.shockwave(at: at, reach: 1100.0, width: 90.0, amount: amount, chroma: 0.6, t0: t0, duration: 1.1))
    }

    static func lens(secondCenter: SIMD2<Float>? = nil, secondRadius: Float = 0, frost: Float = 0.2) -> Fx {
        var p = LensParams()
        if let c = secondCenter, secondRadius > 0 {
            p.second = FxShape.circle(cx: c.x, cy: c.y, r: secondRadius)
        }
        p.frost = frost
        p.bevel = 16.0
        p.depth = 20.0
        p.dispersion = 0.18
        p.magnification = 1.06
        p.unionK = 26.0
        return .lens(p)
    }

    static func plastic(colorIndex: Int, roughness: Float, dome: Float, bevel: Float = 6.0) -> Fx {
        PlasticParams(
            color: rgb(colorIndex),
            roughness: roughness,
            dome: dome,
            bevel: bevel > 0 ? bevel : 6.0,
            angle: -0.6
        ).fx()
    }

    static func pulse(style: PulseStyle = .breathe, colorIndex: Int, period: Float = 2.4, reach: Float = 10.0) -> Fx {
        var p = PulseParams()
        p.style = style
        p.color = rgb(colorIndex)
        p.reach = reach
        p.period = period > 0 ? period : 2.4
        return .pulse(p)
    }

    static func shimmer(intensity: Float, period: Float, band: Float) -> Fx {
        var p = ShimmerParams()
        p.intensity = intensity
        p.period = period
        p.band = band
        return .shimmer(p)
    }

    static func haze(height: Float, amount: Float, wholeShape: Bool = false) -> Fx {
        .distort(.heatHaze(height: height, scale: 14.0, speed: 1.4, amount: amount, wholeShape: wholeShape))
    }

    #if canImport(Metal)
    private final class RendererBox: @unchecked Sendable {
        let renderer: FxRenderer?
        let queue: MTLCommandQueue?
        init() {
            if let dev = MTLCreateSystemDefaultDevice(),
               let q = dev.makeCommandQueue(),
               let r = try? FxRenderer(device: dev, pixelFormat: .rgba8Unorm, options: FxOptions(dither: true, srgbBlend: false)) {
                self.renderer = r
                self.queue = q
            } else {
                self.renderer = nil
                self.queue = nil
            }
        }
    }

    private static let shared = RendererBox()
    #endif

    /// Renders `[FxLayer]` in points `(width, height)` into an `RGBA8Atlas`.
    static func renderAtlas(width: Float, height: Float, scale: Float = 1.0, layers: [FxLayer]) -> RGBA8Atlas {
        let pxW = max(1, Int((width * scale).rounded(.up)))
        let pxH = max(1, Int((height * scale).rounded(.up)))
        #if canImport(Metal)
        guard let renderer = shared.renderer,
              let queue = shared.queue,
              !layers.isEmpty else {
            return RGBA8Atlas(width: pxW, height: pxH)
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: pxW,
            height: pxH,
            mipmapped: false
        )
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: td),
              let cmd = queue.makeCommandBuffer() else {
            return RGBA8Atlas(width: pxW, height: pxH)
        }

        let vp = SIMD2<UInt32>(UInt32(pxW), UInt32(pxH))
        let graph = renderer.prepare(viewport: vp, scale: scale, layers: layers)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            try? renderer.encode(graph: graph, viewport: vp, encoder: enc)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: pxW * pxH * 4)
        tex.getBytes(&bytes, bytesPerRow: pxW * 4, from: MTLRegionMake2D(0, 0, pxW, pxH), mipmapLevel: 0)
        return RGBA8Atlas(width: pxW, height: pxH, texels: bytes)
        #else
        return RGBA8Atlas(width: pxW, height: pxH)
        #endif
    }

    static func fxCanvas<S>(key: String, width: Float = ShowreelKit.W, height: Float = ShowreelKit.H, scale: Float = 1.0, layers: [FxLayer]) -> El<S> {
        let atlas = renderAtlas(width: width, height: height, scale: scale, layers: layers)
        return image(atlas).key(key).absolute(x: 0, y: 0).size(width, height)
    }

    static func fxLayerEl<S>(
        key: String,
        x: Float,
        y: Float,
        w: Float,
        h: Float,
        radius: Float = 0,
        bleed: Float = 0,
        fx: Fx,
        t: Float,
        seed: UInt32 = 1
    ) -> El<S> {
        let cw = max(1, w + 2 * bleed)
        let ch = max(1, h + 2 * bleed)
        let shape = FxShape.rounded(x: bleed, y: bleed, w: max(1, w), h: max(1, h), radius: radius)
        let layer = fx.on(shape).at(t).seed(seed)
        let atlas = renderAtlas(width: cw, height: ch, scale: 1.0, layers: [layer])
        return image(atlas).key(key).absolute(x: x - bleed, y: y - bleed).size(cw, ch)
    }
}

extension PlasticParams {
    func fx() -> Fx {
        .fill(FillParams(.plastic(self)))
    }
}
