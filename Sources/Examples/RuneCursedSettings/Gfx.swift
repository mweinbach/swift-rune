import Foundation
#if canImport(Metal)
import Metal
#endif
import Rune
import RuneFX

/// GPU effects helper for `RuneCursedSettings`, rendering `RuneFX` layers
/// (Firewall flames, Electric fence arcs, Hot-reload embers, Spotlight glow) into `RGBA8Atlas`.
enum CursedGfx {
    static let flushSeconds: Double = 1.6

    #if canImport(Metal)
    private final class Box: @unchecked Sendable {
        let device: MTLDevice?
        let queue: MTLCommandQueue?
        let fx: FxRenderer?

        init() {
            if let dev = MTLCreateSystemDefaultDevice(),
               let q = dev.makeCommandQueue(),
               let r = try? FxRenderer(device: dev, pixelFormat: .rgba8Unorm, options: FxOptions(dither: true, srgbBlend: false)) {
                device = dev
                queue = q
                fx = r
            } else {
                device = nil
                queue = nil
                fx = nil
            }
        }
    }

    private static let shared = Box()
    #endif

    static func renderLayers(width: Float, height: Float, layers: [FxLayer]) -> RGBA8Atlas {
        let w = max(1, Int(width.rounded(.up)))
        let h = max(1, Int(height.rounded(.up)))
        #if canImport(Metal)
        guard let dev = shared.device,
              let queue = shared.queue,
              let fx = shared.fx,
              !layers.isEmpty else {
            return RGBA8Atlas(width: w, height: h)
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = dev.makeTexture(descriptor: td),
              let cmd = queue.makeCommandBuffer() else {
            return RGBA8Atlas(width: w, height: h)
        }

        let vp = SIMD2<UInt32>(UInt32(w), UInt32(h))
        let graph = fx.prepare(viewport: vp, scale: 1.0, layers: layers)

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

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return RGBA8Atlas(width: w, height: h, texels: bytes)
        #else
        return RGBA8Atlas(width: w, height: h)
        #endif
    }

    static func firewallOverlay(width: Float, height: Float, time: Float, reducedMotion: Bool) -> RGBA8Atlas {
        let fire = FireParams(
            style: .border,
            low: rgb(0x8a1405),
            mid: rgb(0xff5a14),
            hot: rgb(0xffc65a),
            height: reducedMotion ? 22.0 : 48.0,
            scale: 20.0,
            speed: reducedMotion ? 0.35 : 1.7,
            intensity: reducedMotion ? 0.65 : 1.15,
            embers: reducedMotion ? 2 : 18,
            emberRise: 56.0,
            emberSize: 0.85,
            emberLife: 1.4,
            warp: reducedMotion ? 0.25 : 1.0,
            sides: 0.45,
            baseGlow: 0.55,
            occlusion: 0.2,
            swirl: 0.0,
            smoke: 0.45
        )
        let shape = FxShape.rounded(x: 36, y: 24, w: max(80, width - 72), h: max(60, height - 48), radius: 10)
        return renderLayers(width: width, height: height, layers: [
            FxLayer(fx: .fire(fire), shape: shape, time: time),
        ])
    }

    static func electricFenceOverlay(width: Float, height: Float, time: Float, reducedMotion: Bool) -> RGBA8Atlas {
        let elec = ElectricParams(
            style: .border,
            color: rgb(0x4f8dff),
            core: rgb(0xeaf3ff),
            cool: rgb(0x7a4dff),
            amplitude: reducedMotion ? 2.0 : 5.5,
            frequency: 2.6,
            speed: reducedMotion ? 0.4 : 3.4,
            coreWidth: 0.65,
            intensity: 1.15,
            glow: 5.5,
            forks: reducedMotion ? 0.15 : 0.6,
            flicker: reducedMotion ? 0.1 : 0.45,
            strands: 2,
            gap: 2.0,
            forkLen: 20.0,
            occlusion: 0.12
        )
        let shape = FxShape.rounded(x: 24, y: 20, w: max(80, width - 48), h: max(60, height - 40), radius: 10)
        return renderLayers(width: width, height: height, layers: [
            FxLayer(fx: .electric(elec), shape: shape, time: time),
        ])
    }

    static func hotReloadOverlay(width: Float, height: Float, time: Float, reducedMotion: Bool) -> RGBA8Atlas {
        let embers = FireParams(
            style: .embers,
            low: rgb(0x8a1405),
            mid: rgb(0xff5a14),
            hot: rgb(0xffc65a),
            height: 28.0,
            scale: 16.0,
            speed: reducedMotion ? 0.3 : 1.5,
            intensity: 1.0,
            embers: reducedMotion ? 4 : 20,
            emberRise: 52.0,
            emberSize: 0.9,
            emberLife: 1.5
        )
        let shape = FxShape.rounded(x: width - 150, y: 12, w: 124, h: 36, radius: 8)
        return renderLayers(width: width, height: height, layers: [
            FxLayer(fx: .fire(embers), shape: shape, time: time),
        ])
    }
}
