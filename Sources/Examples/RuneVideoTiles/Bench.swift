import Foundation
import Metal
import Rune

public struct NativeBenchResult: Sendable {
    public let frames: Int
    public let elapsedSeconds: Double
    public let fps: Double
}

public enum VideoTilesBench {
    public static func runNativeBench(frameCount: Int = 60) throws -> NativeBenchResult {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw NSError(
                domain: "RuneVideoTiles",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"]
            )
        }

        let width: UInt32 = 1280
        let height: UInt32 = 720
        let tileW: UInt32 = 640
        let tileH: UInt32 = 360

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        guard let targetTex = device.makeTexture(descriptor: texDesc) else {
            throw NSError(
                domain: "RuneVideoTiles",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate render target"]
            )
        }

        let renderer = try SurfaceRenderer(device: device, pixelFormat: .bgra8Unorm_srgb)
        let surfaces = (0..<4).map { _ in NativeSurface() }
        let rects: [SIMD4<Float>] = [
            SIMD4<Float>(0, 0, Float(tileW), Float(tileH)),
            SIMD4<Float>(Float(tileW), 0, Float(tileW), Float(tileH)),
            SIMD4<Float>(0, Float(tileH), Float(tileW), Float(tileH)),
            SIMD4<Float>(Float(tileW), Float(tileH), Float(tileW), Float(tileH)),
        ]
        let fullClip = SIMD4<Float>(0, 0, Float(width), Float(height))

        let start = ContinuousClock.now
        let count = max(1, frameCount)
        for frame in 0..<count {
            for i in 0..<surfaces.count {
                let byteFrame = ByteFrame.synthetic(width: tileW, height: tileH, index: UInt64(frame + i))
                #if os(macOS)
                let pb = try CoreVideoPixelBuffer.fromBytes(byteFrame)
                try surfaces[i].push(pb, frameId: UInt64(frame + 1))
                #else
                try surfaces[i].pushBytes(byteFrame, frameId: UInt64(frame + 1))
                #endif
            }

            let draws = (0..<surfaces.count).map { idx in
                SurfaceDraw(
                    surface: surfaces[idx],
                    fit: .fit,
                    beforeInstance: 0,
                    rect: rects[idx],
                    clip: fullClip
                )
            }
            renderer.prepare(draws: draws, viewport: (width, height))

            guard let cmd = queue.makeCommandBuffer() else { continue }
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = targetTex
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
                for idx in 0..<surfaces.count {
                    renderer.draw(encoder: enc, index: idx)
                }
                enc.endEncoding()
            }
            renderer.trackSubmission(commandBuffer: cmd)
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        let duration = ContinuousClock.now - start
        let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let safeElapsed = max(elapsed, 1e-6)
        let fps = Double(count) / safeElapsed
        fputs(
            String(format: "video-tiles native bench: %d frames in %.3fs (%.1f fps)\n", count, safeElapsed, fps),
            stderr
        )
        return NativeBenchResult(frames: count, elapsedSeconds: safeElapsed, fps: fps)
    }
}
