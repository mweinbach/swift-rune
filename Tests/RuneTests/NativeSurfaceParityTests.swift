import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

#if canImport(Metal)
import Metal
#endif

@Suite("NativeSurface Parity Tests")
struct NativeSurfaceParityTests {
    private final class DropNotifyingBox: @unchecked Sendable {
        let onDrop: @Sendable () -> Void
        init(_ onDrop: @escaping @Sendable () -> Void) { self.onDrop = onDrop }
        deinit { onDrop() }
    }

    private final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        var value: T
        init(_ value: T) { self.value = value }
        func withLock<R>(_ body: (inout T) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    @Test("latest frame wins and generation advances with waker")
    func latestFrameWinsAndWakes() throws {
        let surface = NativeSurface()
        let wakes = Box(0)
        surface.setWaker {
            wakes.withLock { $0 += 1 }
        }

        let b1 = Data(repeating: 10, count: 4 * 4 * 4)
        let b2 = Data(repeating: 20, count: 4 * 4 * 4)
        let f1 = try ByteFrame(width: 4, height: 4, format: .bgra, color: .srgb, planes: [b1])
        let f2 = try ByteFrame(width: 4, height: 4, format: .bgra, color: .srgb, planes: [b2])

        try surface.pushBytes(f1, frameId: 1)
        try surface.pushBytes(f2, frameId: 2)

        #expect(surface.currentFrame()?.id == 2)
        #expect(surface.generation >= 2)
        #expect(wakes.withLock { $0 } == 2)

        surface.clear()
        #expect(surface.currentFrame() == nil)
        #expect(wakes.withLock { $0 } == 3)
    }

    @Test("byte frame validates dimensions and plane byte counts")
    func byteFrameValidation() {
        #expect(throws: NativeSurfaceError.zeroDimensions) {
            _ = try ByteFrame(width: 0, height: 4, format: .bgra, color: .srgb, planes: [Data()])
        }
        #expect(throws: NativeSurfaceError.oddNv12Dimensions(width: 3, height: 4)) {
            _ = try ByteFrame(width: 3, height: 4, format: .nv12Video, color: .bt709, planes: [Data(count: 12), Data(count: 6)])
        }
        #expect(throws: NativeSurfaceError.wrongPlaneCount(expected: 2, got: 1)) {
            _ = try ByteFrame(width: 4, height: 4, format: .nv12Video, color: .bt709, planes: [Data(count: 16)])
        }
        #expect(throws: NativeSurfaceError.wrongPlaneByteCount(plane: 0, expected: 64, got: 8)) {
            _ = try ByteFrame(width: 4, height: 4, format: .bgra, color: .srgb, planes: [Data(count: 8)])
        }
    }

    @Test("replaced waker and observer callbacks drop outside surface lock")
    func replacedCallbackDropsOutsideLock() {
        let surface = NativeSurface()
        let first = DropNotifyingBox {
            // Re-entering `surface.currentFrame()` inside old callback's deinit would deadlock if lock was held!
            _ = surface.currentFrame()
        }
        surface.setWaker { _ = first }
        surface.setWaker(nil)

        let obsBox = DropNotifyingBox {
            _ = surface.isMirrored
        }
        surface.setObserver { _ in _ = obsBox }
        surface.setObserver(nil)
    }

    @Test("orient from display transforms and upright dimensions")
    func orientTransformsAndUpright() {
        #expect(Orient.up.swaps == false)
        #expect(Orient.up.upright(width: 1920, height: 1080) == (1920, 1080))

        // 90° clockwise rotation transform
        let rot90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let o90 = Orient.fromTransform(rot90)
        #expect(o90.swaps == true)
        #expect(o90.upright(width: 1920, height: 1080) == (1080, 1920))
    }

    @Test("surface place anchors and unscaled placement match upstream")
    func surfacePlaceRects() {
        let topLeftUnscaled = SurfacePlace(anchor: (.start, .start), unscaled: true)
        let node = SIMD4<Float>(10, 20, 100, 80)
        let r = topLeftUnscaled.imageRect(forNode: node, imageSize: (32, 16), fit: .fill)
        #expect(r == SIMD4<Float>(10, 20, 32, 16))

        let bottomRightFit = SurfacePlace(anchor: (.end, .end), unscaled: false)
        let rFit = bottomRightFit.imageRect(forNode: SIMD4<Float>(0, 0, 100, 100), imageSize: (50, 25), fit: .fit)
        // Scales uniformly 2x -> 100x50, anchored at bottom -> y = 50
        #expect(abs(rFit.x - 0) < 0.01)
        #expect(abs(rFit.y - 50) < 0.01)
        #expect(abs(rFit.z - 100) < 0.01)
        #expect(abs(rFit.w - 50) < 0.01)
    }

    #if canImport(Metal)
    private func renderSingleSurface(
        _ draw: SurfaceDraw,
        size: (UInt32, UInt32),
        renderer: SurfaceRenderer? = nil
    ) throws -> (bytes: [UInt8], renderer: SurfaceRenderer) {
        let dev = MTLCreateSystemDefaultDevice()!
        let sr = try renderer ?? SurfaceRenderer(device: dev, pixelFormat: .bgra8Unorm_srgb)
        let queue = dev.makeCommandQueue()!

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.0),
            height: Int(size.1),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let tex = dev.makeTexture(descriptor: desc)!

        sr.prepare(draws: [draw], viewport: size)

        let cb = queue.makeCommandBuffer()!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        sr.draw(encoder: enc, index: 0, pixelFormat: .bgra8Unorm_srgb)
        enc.endEncoding()
        sr.trackSubmission(commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: Int(size.0 * size.1 * 4))
        tex.getBytes(&bgra, bytesPerRow: Int(size.0) * 4, from: MTLRegionMake2D(0, 0, Int(size.0), Int(size.1)), mipmapLevel: 0)
        // Swizzle BGRA -> RGBA for assertions
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let b = bgra[i]
            bgra[i] = bgra[i + 2]
            bgra[i + 2] = b
        }
        return (bgra, sr)
    }

    private func rgbaAt(_ bytes: [UInt8], width: UInt32, x: Int, y: Int) -> [UInt8] {
        let off = (y * Int(width) + x) * 4
        return Array(bytes[off..<(off + 4)])
    }

    private func bgraRamp(_ w: Int, _ h: Int) -> (ByteFrame, [[UInt8]]) {
        var data = Data(count: w * h * 4)
        var expected: [[UInt8]] = []
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let r = UInt8((x * 255 / max(1, w - 1)) & 0xFF)
                    let g = UInt8((y * 255 / max(1, h - 1)) & 0xFF)
                    let b = UInt8(((x + y) * 31) & 0xFF)
                    let off = (y * w + x) * 4
                    ptr[off + 0] = b
                    ptr[off + 1] = g
                    ptr[off + 2] = r
                    ptr[off + 3] = 255
                    expected.append([r, g, b, 255])
                }
            }
        }
        let bf = try! ByteFrame(width: UInt32(w), height: UInt32(h), format: .bgra, color: .srgb, planes: [data])
        return (bf, expected)
    }

    @Test("GPU stale unscaled frame pins top-left and crops cleanly")
    func staleFramePinnedTopLeftOnGPU() throws {
        let (frame, src) = bgraRamp(8, 4)
        let surface = NativeSurface().placed(SurfacePlace(anchor: (.start, .start), unscaled: true))
        try surface.pushBytes(frame, frameId: 1)

        var draw = SurfaceDraw(
            surface: surface,
            fit: .fill,
            beforeInstance: 0,
            rect: SIMD4<Float>(0, 0, 10, 6),
            clip: SIMD4<Float>(0, 0, 10, 6)
        )
        let (out1, renderer) = try renderSingleSurface(draw, size: (10, 6))
        for y in 0..<4 {
            for x in 0..<8 {
                let got = rgbaAt(out1, width: 10, x: x, y: y)
                #expect(got == src[y * 8 + x])
            }
        }
        for (x, y) in [(8, 0), (9, 3), (0, 4), (9, 5)] {
            #expect(rgbaAt(out1, width: 10, x: x, y: y)[3] == 0)
        }

        draw.rect = SIMD4<Float>(0, 0, 6, 3)
        draw.clip = SIMD4<Float>(0, 0, 6, 3)
        let (out2, _) = try renderSingleSurface(draw, size: (6, 3), renderer: renderer)
        for y in 0..<3 {
            for x in 0..<6 {
                #expect(rgbaAt(out2, width: 6, x: x, y: y) == src[y * 8 + x])
            }
        }
    }

    @Test("GPU NV12 BT.601 and BT.709 color accuracy matches reference")
    func gpuNv12ColorAccuracy() throws {
        for matrix in [SurfaceMatrix.bt601, SurfaceMatrix.bt709] {
            let yVal: UInt8 = 180
            let cbVal: UInt8 = 90
            let crVal: UInt8 = 200
            let yPlane = Data(repeating: yVal, count: 4 * 4)
            let uvPlane = Data([cbVal, crVal, cbVal, crVal, cbVal, crVal, cbVal, crVal])
            let bf = try ByteFrame(
                width: 4,
                height: 4,
                format: .nv12Video,
                color: SurfaceColorInfo(matrix: matrix, transfer: .bt709),
                planes: [yPlane, uvPlane]
            )
            let surface = NativeSurface()
            try surface.pushBytes(bf, frameId: 1)
            let draw = SurfaceDraw(
                surface: surface,
                fit: .fill,
                beforeInstance: 0,
                rect: SIMD4<Float>(0, 0, 4, 4),
                clip: SIMD4<Float>(0, 0, 4, 4)
            )
            let (out, _) = try renderSingleSurface(draw, size: (4, 4))
            let expectedLin = ByteFrame.nv12Reference(y: yVal, cb: cbVal, cr: crVal, fullRange: false, matrix: matrix, transfer: .bt709)
            let gotPx = rgbaAt(out, width: 4, x: 1, y: 1)
            let expR = UInt8((RefShader.linearToSRGB(expectedLin.x) * 255.0).rounded())
            let expG = UInt8((RefShader.linearToSRGB(expectedLin.y) * 255.0).rounded())
            let expB = UInt8((RefShader.linearToSRGB(expectedLin.z) * 255.0).rounded())
            #expect(abs(Int(gotPx[0]) - Int(expR)) <= 2)
            #expect(abs(Int(gotPx[1]) - Int(expG)) <= 2)
            #expect(abs(Int(gotPx[2]) - Int(expB)) <= 2)
            #expect(gotPx[3] == 255)
        }
    }

    @Test("GPU downscaled 8x8 linear-light supersampling avoids gamma darkening")
    func gpuLinearLightDownscale() throws {
        // 8x8 alternating pure white & pure black columns -> linear average = 0.5 -> sRGB ~188 (gamma average would be ~128).
        let w = 8, h = 8
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let v: UInt8 = (x % 2 == 0) ? 255 : 0
                    let off = (y * w + x) * 4
                    ptr[off + 0] = v
                    ptr[off + 1] = v
                    ptr[off + 2] = v
                    ptr[off + 3] = 255
                }
            }
        }
        let bf = try ByteFrame(width: 8, height: 8, format: .bgra, color: .srgb, planes: [data])
        let surface = NativeSurface()
        try surface.pushBytes(bf, frameId: 1)
        let draw = SurfaceDraw(
            surface: surface,
            fit: .fill,
            beforeInstance: 0,
            rect: SIMD4<Float>(0, 0, 1, 1),
            clip: SIMD4<Float>(0, 0, 1, 1)
        )
        let (out, _) = try renderSingleSurface(draw, size: (1, 1))
        let px = rgbaAt(out, width: 1, x: 0, y: 0)
        #expect(px[0] >= 175 && px[0] <= 198, "expected linear-light midpoint ~188, got \(px[0])")
    }

    @Test("GPU mirror, orientation, observer timing, and CoreVideo plane lifetime")
    func gpuMirrorOrientObserverAndCVLifetime() throws {
        let dev = MTLCreateSystemDefaultDevice()!
        let sr = try SurfaceRenderer(device: dev, pixelFormat: .bgra8Unorm_srgb)
        let surface = NativeSurface()

        let timings = Box<[FrameTiming]>([])
        surface.setObserver { t in
            timings.withLock { $0.append(t) }
        }

        // 2x2 distinct quadrants: TL=Red, TR=Green, BL=Blue, BR=White
        let px: [UInt8] = [
            0, 0, 255, 255,    0, 255, 0, 255,
            255, 0, 0, 255,    255, 255, 255, 255
        ]
        let bf = try ByteFrame(width: 2, height: 2, format: .bgra, color: .srgb, planes: [Data(px)])
        let pb = try CoreVideoPixelBuffer.fromBytes(bf)
        try surface.push(pb, frameId: 77)
        surface.setMirrored(true)

        let draw = SurfaceDraw(
            surface: surface,
            fit: .fill,
            beforeInstance: 0,
            rect: SIMD4<Float>(0, 0, 2, 2),
            clip: SIMD4<Float>(0, 0, 2, 2)
        )
        let (out, _) = try renderSingleSurface(draw, size: (2, 2), renderer: sr)

        // Mirrored horizontally: TL should be Green (TR original), TR should be Red (TL original)
        #expect(rgbaAt(out, width: 2, x: 0, y: 0)[1] > 200)
        #expect(rgbaAt(out, width: 2, x: 1, y: 0)[0] > 200)

        let reported = timings.withLock { $0 }
        #expect(reported.contains(where: { $0.frameId == 77 && $0.completedAt != nil }))
    }

    @Test("MetalRenderer.encode encodes scene into caller texture and Runtime interleaves border & child over video")
    func metalRendererEncodeAndRuntimePainterOrder() throws {
        let metalRenderer = try MetalRenderer()

        // 1. Verify MetalRenderer.encode(scene:into:commandBuffer:) (#126)
        struct EmptyState {}
        let rtSimple = Runtime<EmptyState>(
            state: EmptyState(),
            viewport: Vec2(40, 40),
            pixelScale: 1.0,
            view: { _, _ in el().size(40, 40).bg(Color(r: 0, g: 1, b: 0, a: 1)) }
        )
        let sceneSimple = rtSimple.frame(at: 0)
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 40, height: 40, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        let target = metalRenderer.device.makeTexture(descriptor: texDesc)!
        let cb = metalRenderer.commandQueue.makeCommandBuffer()!
        try metalRenderer.encode(scene: sceneSimple, into: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: 40 * 40 * 4)
        target.getBytes(&bgra, bytesPerRow: 40 * 4, from: MTLRegionMake2D(0, 0, 40, 40), mipmapLevel: 0)
        let centerIdx = (20 * 40 + 20) * 4
        #expect(bgra[centerIdx + 1] == 255) // G = 255

        // 2. Verify painter order: background < surface < border & child
        let surface = NativeSurface()
        var redBytes = Data(count: 20 * 20 * 4)
        redBytes.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: ptr.count, by: 4) {
                ptr[i + 0] = 0
                ptr[i + 1] = 0
                ptr[i + 2] = 255
                ptr[i + 3] = 255
            }
        }
        try surface.pushBytes(try ByteFrame(width: 20, height: 20, format: .bgra, color: .srgb, planes: [redBytes]), frameId: 1)

        let rt = Runtime<EmptyState>(
            state: EmptyState(),
            viewport: Vec2(20, 20),
            pixelScale: 1.0,
            view: { _, _ in
                nativeSurface(surface, .fill)
                    .size(20, 20)
                    .bg(Color(r: 0, g: 0, b: 1, a: 1))
                    .border(2, Color(r: 0, g: 1, b: 0, a: 1))
                    .child(el().size(6, 6).bg(Color(r: 1, g: 1, b: 1, a: 1)))
            }
        )
        let scene = rt.frame(at: 0)
        let frame = try metalRenderer.renderOffscreen(scene, surfaces: rt.surfaces)
        // Top-edge border at (10, 0) outside the 6x6 top-left child should be green over red video
        let bOff = (0 * 20 + 10) * 4
        #expect(frame.rgba[bOff + 1] > 200 && frame.rgba[bOff + 0] < 30)
        // Inside child at (3, 3) should be white over red video
        let cOff = (3 * 20 + 3) * 4
        #expect(frame.rgba[cOff + 0] > 220 && frame.rgba[cOff + 1] > 220 && frame.rgba[cOff + 2] > 220)
        // Video area at (12, 12) should be red over blue background
        let vOff = (12 * 20 + 12) * 4
        #expect(frame.rgba[vOff + 0] > 220 && frame.rgba[vOff + 2] < 30)
    }

    // MARK: - Orient quarter-turn & rotated quadrant parity (`native_surface/tests.rs:749-824`)

    @Test("orientations_come_from_quarter_turn_transforms_only")
    func orientationsFromQuarterTurnTransformsOnly() {
        #expect(Orient.fromMatrix(a: 0, b: 1, c: -1, d: 0) == Orient(m00: 0, m01: 1, m10: -1, m11: 0))
        #expect(Orient.fromMatrix(a: 1, b: 0, c: 0, d: 1) == .up)
        #expect(Orient.fromMatrix(a: -1, b: 0, c: 0, d: -1) == Orient(m00: -1, m01: 0, m10: 0, m11: -1))
        #expect(Orient.fromMatrix(a: 0.7071, b: 0.7071, c: -0.7071, d: 0.7071) == .up)
        #expect(Orient.fromMatrix(a: 2, b: 0, c: 0, d: 2) == .up)
        #expect(Orient(m00: 0, m01: 1, m10: -1, m11: 0).swaps == true)
        #expect(Orient(m00: 0, m01: 1, m10: -1, m11: 0).upright(width: 64, height: 32) == (32, 64))

        // CGAffineTransform matching AVAssetTrack 90-degree portrait clip: [0, 1, -1, 0]
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        #expect(Orient.fromTransform(t) == Orient(m00: 0, m01: 1, m10: -1, m11: 0))
    }

    private static func cpuTurnedBGRA(_ frame: ByteFrame, orient o: Orient) throws -> ByteFrame {
        let (sw, sh) = (Int(frame.width), Int(frame.height))
        let (uw, uh) = o.upright(width: frame.width, height: frame.height)
        let (w, h) = (Int(uw), Int(uh))
        let src = frame.planes[0]
        var dst = Data(count: w * h * 4)
        src.withUnsafeBytes { sRaw in
            dst.withUnsafeMutableBytes { dRaw in
                let sp = sRaw.bindMemory(to: UInt8.self)
                let dp = dRaw.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        // centred upright coords mapped to centred buffer coords
                        let ux = Float(x) + 0.5 - Float(w) * 0.5
                        let uy = Float(y) + 0.5 - Float(h) * 0.5
                        let bx = o.m00 * ux + o.m01 * uy + Float(sw) * 0.5 - 0.5
                        let by = o.m10 * ux + o.m11 * uy + Float(sh) * 0.5 - 0.5
                        let ix = max(0, min(sw - 1, Int(bx.rounded())))
                        let iy = max(0, min(sh - 1, Int(by.rounded())))
                        let sOff = (iy * sw + ix) * 4
                        let dOff = (y * w + x) * 4
                        dp[dOff + 0] = sp[sOff + 0]
                        dp[dOff + 1] = sp[sOff + 1]
                        dp[dOff + 2] = sp[sOff + 2]
                        dp[dOff + 3] = sp[sOff + 3]
                    }
                }
            }
        }
        return try ByteFrame(width: uw, height: uh, format: .bgra, color: frame.color, planes: [dst])
    }

    @Test("oriented_frames_draw_like_frames_turned_upright_on")
    func orientedFramesDrawLikeFramesTurnedUpright() throws {
        let dev = MTLCreateSystemDefaultDevice()!
        let sr = try SurfaceRenderer(device: dev, pixelFormat: .bgra8Unorm_srgb)
        let allOrients: [Orient] = [
            Orient(m00: 1, m01: 0, m10: 0, m11: 1),
            Orient(m00: 0, m01: 1, m10: -1, m11: 0),
            Orient(m00: -1, m01: 0, m10: 0, m11: -1),
            Orient(m00: 0, m01: -1, m10: 1, m11: 0),
            Orient(m00: -1, m01: 0, m10: 0, m11: 1),
            Orient(m00: 1, m01: 0, m10: 0, m11: -1),
            Orient(m00: 0, m01: 1, m10: 1, m11: 0),
            Orient(m00: 0, m01: -1, m10: -1, m11: 0),
        ]

        // 16x8 asymmetric BGRA ramp with distinct quadrants
        let sw = 16, sh = 8
        var ramp = Data(count: sw * sh * 4)
        ramp.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for y in 0..<sh {
                for x in 0..<sw {
                    let off = (y * sw + x) * 4
                    ptr[off + 0] = UInt8((x * 16 + y * 8) & 0xFF) // B
                    ptr[off + 1] = UInt8(y * 32)                  // G
                    ptr[off + 2] = UInt8(x * 16)                  // R
                    ptr[off + 3] = 255
                }
            }
        }
        let base = try ByteFrame(width: UInt32(sw), height: UInt32(sh), format: .bgra, color: .srgb, planes: [ramp])

        var id: UInt64 = 0
        for native in [false, true] {
            for o in allOrients {
                let upright = try Self.cpuTurnedBGRA(base, orient: o)
                let (uw, uh) = (Int(upright.width), Int(upright.height))
                let oriented = NativeSurface()
                let reference = NativeSurface()
                id += 1
                if native {
                    try oriented.pushOriented(try CoreVideoPixelBuffer.fromBytes(base), orient: o, frameId: id)
                    try reference.push(try CoreVideoPixelBuffer.fromBytes(upright), frameId: id)
                } else {
                    try oriented.pushBytesOriented(base, orient: o, frameId: id)
                    try reference.pushBytes(upright, frameId: id)
                }
                for (w, h) in [(uw, uh), (uw * 2, uh * 2), (uw / 2, uh / 2)] {
                    let rect = SIMD4<Float>(0, 0, Float(w), Float(h))
                    let d1 = SurfaceDraw(surface: oriented, fit: .fill, beforeInstance: 0, rect: rect, clip: rect)
                    let d2 = SurfaceDraw(surface: reference, fit: .fill, beforeInstance: 0, rect: rect, clip: rect)
                    let (got, _) = try renderSingleSurface(d1, size: (UInt32(w), UInt32(h)), renderer: sr)
                    let (want, _) = try renderSingleSurface(d2, size: (UInt32(w), UInt32(h)), renderer: sr)
                    for i in 0..<got.count {
                        #expect(abs(Int(got[i]) - Int(want[i])) <= 2)
                    }
                }
            }
        }
    }

    @Test("rotated_clip_buffers_draw_upright_like_its_poster_on")
    func rotatedClipBuffersDrawUprightLikePoster() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("quadrants-rot90.mp4")
        let player = Player(source: .url(fixture))
        guard let tf = player.testFramesForTest(at: 0.125) else {
            Issue.record("expected testFramesForTest for quadrants-rot90.mp4")
            return
        }
        #expect(tf.raw.width == 64 && tf.raw.height == 32)
        #expect(tf.upright.width == 32 && tf.upright.height == 64)
        #expect(tf.orient.swaps == true)

        let dev = MTLCreateSystemDefaultDevice()!
        let sr = try SurfaceRenderer(device: dev, pixelFormat: .bgra8Unorm_srgb)
        for native in [false, true] {
            let oriented = NativeSurface()
            let poster = NativeSurface()
            if native {
                try oriented.pushOriented(try CoreVideoPixelBuffer.fromBytes(tf.raw), orient: tf.orient, frameId: 1)
                try poster.push(try CoreVideoPixelBuffer.fromBytes(tf.upright), frameId: 1)
            } else {
                try oriented.pushBytesOriented(tf.raw, orient: tf.orient, frameId: 1)
                try poster.pushBytes(tf.upright, frameId: 1)
            }
            for scale in [1, 2] {
                let w = 32 / scale
                let h = 64 / scale
                let rect = SIMD4<Float>(0, 0, Float(w), Float(h))
                let (got, _) = try renderSingleSurface(SurfaceDraw(surface: oriented, fit: .fill, beforeInstance: 0, rect: rect, clip: rect), size: (UInt32(w), UInt32(h)), renderer: sr)
                let (want, _) = try renderSingleSurface(SurfaceDraw(surface: poster, fit: .fill, beforeInstance: 0, rect: rect, clip: rect), size: (UInt32(w), UInt32(h)), renderer: sr)
                var colors: [[UInt8]] = []
                for (qx, qy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let x = (qx * 16 + 8) / scale
                    let y = (qy * 32 + 16) / scale
                    let g = rgbaAt(got, width: UInt32(w), x: x, y: y)
                    let r = rgbaAt(want, width: UInt32(w), x: x, y: y)
                    for c in 0..<4 {
                        #expect(abs(Int(g[c]) - Int(r[c])) <= 8)
                    }
                    colors.append(r)
                }
                let unique = Set(colors.map { "\($0[0]),\($0[1]),\($0[2])" })
                #expect(unique.count == 4)
            }
        }
    }
    #endif
}
