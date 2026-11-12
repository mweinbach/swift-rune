import Foundation
#if canImport(Metal)
import Metal
#endif
import Rune
import RuneFX
import RuneKit
import RuneLight
import RuneMotion

/// Port of `examples/site-scenes`: material stills for Rune's home page (`metal`, `glass`, `light`)
/// rendered via `RuneFX` (`LiquidMetalParams` + `FxRenderer`) and `RuneLight` (`GlassRenderer`, `LightRenderer`).
enum SiteSceneKind: String, CaseIterable, CustomStringConvertible {
    case metal
    case glass
    case light

    var description: String { rawValue.capitalized }
}

private let stageW: Float = 960
private let stageH: Float = 540
private let hue: Float = 245.0

struct SiteScenesState {
    var scene: SiteSceneKind = .metal
    var t: Float = 1.2
    var cachedKey: String = ""
    var cachedAtlas: RGBA8Atlas? = nil
}

#if canImport(Metal)
private final class SiteGPU: @unchecked Sendable {
    static let shared = SiteGPU()
    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let fx: FxRenderer?
    let glass: GlassRenderer?

    init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            device = nil
            queue = nil
            fx = nil
            glass = nil
            return
        }
        device = dev
        queue = q
        fx = try? FxRenderer(device: dev, pixelFormat: .rgba8Unorm, options: FxOptions(dither: true, srgbBlend: false))
        glass = try? GlassRenderer(device: dev, pixelFormat: .rgba8Unorm)
    }

    func makeTexture(w: Int, h: Int, format: MTLPixelFormat = .rgba8Unorm) -> MTLTexture? {
        guard let device else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    func readAtlas(from tex: MTLTexture) -> RGBA8Atlas {
        let w = tex.width
        let h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return RGBA8Atlas(width: w, height: h, texels: bytes)
    }
}

private func rgbHex(_ hex: UInt32) -> SIMD3<Float> {
    SIMD3<Float>(
        Float((hex >> 16) & 0xFF) / 255.0,
        Float((hex >> 8) & 0xFF) / 255.0,
        Float(hex & 0xFF) / 255.0
    )
}

private func renderMetalAtlas(t: Float) -> RGBA8Atlas {
    let w = Int(stageW)
    let h = Int(stageH)
    guard let fx = SiteGPU.shared.fx,
          let queue = SiteGPU.shared.queue,
          let tex = SiteGPU.shared.makeTexture(w: w, h: h),
          let cmd = queue.makeCommandBuffer() else {
        return RGBA8Atlas(width: w, height: h)
    }

    let cx = stageW * 0.5
    let cy = stageH * 0.5
    let r: Float = 92.0

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

    let layer = FxLayer(
        fx: .fill(FillParams(FillStyle.liquidMetal(params))),
        shape: .circle(cx: cx, cy: cy, r: r),
        time: t
    )

    let vp = SIMD2<UInt32>(UInt32(w), UInt32(h))
    let graph = fx.prepare(viewport: vp, scale: 1.0, layers: [layer])

    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = tex
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
        try? fx.encode(graph: graph, viewport: vp, encoder: enc)
        enc.endEncoding()
    }
    cmd.commit()
    cmd.waitUntilCompleted()
    return SiteGPU.shared.readAtlas(from: tex)
}

private func renderLightAtlas(t: Float) -> RGBA8Atlas {
    let w = Int(stageW)
    let h = Int(stageH)
    guard let dev = SiteGPU.shared.device,
          let queue = SiteGPU.shared.queue,
          let renderer = try? LightRenderer(device: dev, width: UInt32(w), height: UInt32(h), outputFormat: .rgba8Unorm),
          let baseTex = SiteGPU.shared.makeTexture(w: w, h: h),
          let textTex = SiteGPU.shared.makeTexture(w: w, h: h),
          let outTex = SiteGPU.shared.makeTexture(w: w, h: h),
          let cmd = queue.makeCommandBuffer() else {
        return RGBA8Atlas(width: w, height: h)
    }

    // Clear base & text textures to dark floor / transparent
    let clearBase = MTLRenderPassDescriptor()
    clearBase.colorAttachments[0].texture = baseTex
    clearBase.colorAttachments[0].loadAction = .clear
    clearBase.colorAttachments[0].storeAction = .store
    clearBase.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.022, blue: 0.028, alpha: 1.0)
    if let enc = cmd.makeRenderCommandEncoder(descriptor: clearBase) { enc.endEncoding() }

    let clearText = MTLRenderPassDescriptor()
    clearText.colorAttachments[0].texture = textTex
    clearText.colorAttachments[0].loadAction = .clear
    clearText.colorAttachments[0].storeAction = .store
    clearText.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    if let enc = cmd.makeRenderCommandEncoder(descriptor: clearText) { enc.endEncoding() }

    let cx = stageW * 0.5
    let cy = stageH * 0.5
    let s: Float = 60.0
    let gap: Float = 16.0
    var prims: [Prim] = []
    for i in 0..<3 {
        for j in 0..<3 {
            let x = cx - 1.5 * s - gap + Float(j) * (s + gap)
            let y = cy - 1.5 * s - gap + Float(i) * (s + gap)
            let lit = (i == 1 && j == 1)
            let c = lit ? oklch(0.55, 0.15, hue) : oklch(0.4, 0.005, hue)
            var p = Prim.rect(x, y, s, s)
                .radius(16.0)
                .raised(12.0)
                .bevel(width: 12.0, height: 4.0)
                .gloss(0.8, roughness: 0.3)
                .albedo(SIMD3<Float>(c.r, c.g, c.b))
            if lit {
                p = p.emissive(SIMD3<Float>(0.006, 0.024, 0.08))
            }
            prims.append(p)
        }
    }

    let angle: Float = -2.25 + 0.12 * sinf(t * 0.5)
    let keyCol = oklch(0.97, 0.012, hue)
    let key = Light.point(cx + 150.0 * cosf(angle), cy + 130.0 * sinf(angle), 200.0)
        .color(SIMD3<Float>(keyCol.r, keyCol.g, keyCol.b))
        .intensity(2.6)
        .radius(40.0)
        .range(1000.0)
        .specular(2.6)

    let fillCol = oklch(0.72, 0.12, hue)
    let fill = Light.point(cx + 420.0, cy - 300.0, 420.0)
        .color(SIMD3<Float>(fillCol.r, fillCol.g, fillCol.b))
        .intensity(0.35)
        .radius(160.0)
        .range(2400.0)
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

    let scene = LightScene(prims: prims, lights: [key, fill], settings: settings)
    _ = renderer.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: outTex)
    cmd.commit()
    cmd.waitUntilCompleted()
    return SiteGPU.shared.readAtlas(from: outTex)
}

private func renderGlassAtlas(t: Float) -> RGBA8Atlas {
    let w = Int(stageW)
    let h = Int(stageH)
    guard let glassRenderer = SiteGPU.shared.glass,
          let queue = SiteGPU.shared.queue,
          let baseTex = SiteGPU.shared.makeTexture(w: w, h: h, format: .rgba16Float),
          let pyrTex = SiteGPU.shared.makeTexture(w: w, h: h, format: .rgba16Float),
          let outTex = SiteGPU.shared.makeTexture(w: w, h: h, format: .rgba8Unorm),
          let cmd = queue.makeCommandBuffer() else {
        return RGBA8Atlas(width: w, height: h)
    }

    // Draw orb into baseTex on CPU->MTL upload via rgba8 intermediate or clear + glass pass
    let cx = stageW * 0.5
    let cy = stageH * 0.5
    let orbX = cx - 48.0 + sinf(t * 0.35 + cx - 48.0) * 6.0
    let orbY = cy - 50.0 + cosf(t * 0.3 + cy - 50.0) * 4.0
    let orbR: Float = 100.0
    let orbCol = oklch(0.62, 0.16, hue)

    var basePixels = [Float16](repeating: Float16(0), count: w * h * 4)
    for py in 0..<h {
        let dy = Float(py) - orbY
        for px in 0..<w {
            let dx = Float(px) - orbX
            let dist = sqrtf(dx * dx + dy * dy)
            let disc = max(0.0, min(1.0, orbR - dist + 0.5))
            let halo = powf(max(0.0, 1.0 - dist / (orbR * 2.4)), 3.0) * 0.3
            let a = max(disc, halo)
            let idx = (py * w + px) * 4
            basePixels[idx] = Float16(orbCol.r * a)
            basePixels[idx + 1] = Float16(orbCol.g * a)
            basePixels[idx + 2] = Float16(orbCol.b * a)
            basePixels[idx + 3] = Float16(1.0)
        }
    }
    basePixels.withUnsafeBytes { ptr in
        baseTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: w * 8)
    }

    // Build pyramid blur mip/pass
    let pyrRpd = MTLRenderPassDescriptor()
    pyrRpd.colorAttachments[0].texture = pyrTex
    pyrRpd.colorAttachments[0].loadAction = .clear
    pyrRpd.colorAttachments[0].storeAction = .store
    pyrRpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    if let enc = cmd.makeRenderCommandEncoder(descriptor: pyrRpd) {
        enc.setRenderPipelineState(glassRenderer.pyramidPipeline)
        enc.setFragmentTexture(baseTex, index: 0)
        var texel = SIMD4<Float>(1.0 / Float(w), 1.0 / Float(h), 0, 0)
        enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    let pane = SIMD4<Float>(cx - 70.0, cy - 110.0, 220.0, 220.0)
    let slab = Glass.rounded(pane.x, pane.y, pane.z, pane.w, radius: 50.0)
        .thickness(40.0)
        .bevel(34.0)
        .dome(6.0)
        .gap(16.0)
        .ior(1.5)
        .dispersion(0.025)
        .frost(0.6)
        .tint(SIMD3<Float>(0.0005, 0.00035, 0.0002))

    let lamp = GlassLight(
        pos: SIMD4<Float>(pane.x + pane.z * 0.3, pane.y - 220.0, 420.0, 260.0),
        color: SIMD4<Float>(0.9, 1.0, 1.15, 0.0)
    )
    let settings = GlassSettings(env: 0.45, shadow: 0.6, shadowOffset: SIMD2<Float>(0, 24.0), shadowBlur: 36.0, caustic: 0.5)
    var uniforms = GlassUniforms()
    uniforms.size = SIMD4<Float>(stageW, stageH, 1.0 / stageW, 1.0 / stageH)
    uniforms.misc = SIMD4<Float>(1, 1, settings.env, settings.caustic)
    uniforms.shadow = SIMD4<Float>(settings.shadowOffset.x, settings.shadowOffset.y, settings.shadowBlur, settings.shadow)

    let mainRpd = MTLRenderPassDescriptor()
    mainRpd.colorAttachments[0].texture = outTex
    mainRpd.colorAttachments[0].loadAction = .clear
    mainRpd.colorAttachments[0].storeAction = .store
    mainRpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    if let enc = cmd.makeRenderCommandEncoder(descriptor: mainRpd) {
        enc.setRenderPipelineState(glassRenderer.mainPipeline)
        enc.setFragmentTexture(baseTex, index: 0)
        enc.setFragmentTexture(pyrTex, index: 1)
        enc.setFragmentTexture(baseTex, index: 2)
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
    return SiteGPU.shared.readAtlas(from: outTex)
}
#endif

private func atlasForScene(_ scene: SiteSceneKind, t: Float) -> RGBA8Atlas {
    #if canImport(Metal)
    switch scene {
    case .metal: return renderMetalAtlas(t: t)
    case .glass: return renderGlassAtlas(t: t)
    case .light: return renderLightAtlas(t: t)
    }
    #else
    return RGBA8Atlas(width: Int(stageW), height: Int(stageH))
    #endif
}

func siteScenesView(_ s: SiteScenesState, _ cx: inout Cx<SiteScenesState>) -> El<SiteScenesState> {
    let atlas = atlasForScene(s.scene, t: s.t)
    let accent = oklch(0.74, 0.14, hue)

    var pills: El<SiteScenesState> = row()
        .gap(8)
        .p(8)
        .rounded(20)
        .bg(Color.black.alpha(0.65))
        .border(1, Color.white.alpha(0.12))
    for kind in SiteSceneKind.allCases {
        let active = (kind == s.scene)
        let pill: El<SiteScenesState> = row()
            .key("scene-\(kind.rawValue)")
            .role(.tab)
            .label(kind.description)
            .selected(active ? "true" : "false")
            .px(14)
            .py(6)
            .rounded(14)
            .bg(active ? accent.alpha(0.25) : Color.transparent)
            .border(1, active ? accent : Color.transparent)
            .pressScale(0.95)
            .onClick { state in state.scene = kind }
            .child(
                text(kind.description)
                    .font(Tok.Typography.label)
                    .color(active ? .white : Color.white.alpha(0.6))
            )
        pills = pills.child(pill)
    }

    return el()
        .sizeFull()
        .bg(.black)
        .child(
            image(atlas)
                .key("scene-render")
                .sizeFull()
        )
        .child(
            row()
                .absolute(x: 20, y: 20)
                .child(pills)
        )
}

let spec = AppSpec<SiteScenesState>(
    title: "Rune Site Scenes",
    size: Vec2(stageW, stageH),
    state: SiteScenesState(),
    onKey: { state, event, _ in
        switch event.key {
        case .text("1"): state.scene = .metal; return true
        case .text("2"): state.scene = .glass; return true
        case .text("3"): state.scene = .light; return true
        default: return false
        }
    },
    view: siteScenesView
)
.scene("metal") { $0.scene = .metal }
.scene("glass") { $0.scene = .glass }
.scene("light") { $0.scene = .light }

try RuneApp.run(spec)
