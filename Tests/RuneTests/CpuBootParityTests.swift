import Foundation
import Testing
@testable import Rune

#if canImport(Metal)
import Metal
#endif

@Suite("CpuBoot Parity Tests")
struct CpuBootParityTests {
    private func rect(
        _ rect: SIMD4<Float>,
        fill: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        border: SIMD4<Float> = .zero,
        borderWidth: Float = 0,
        clip: SIMD4<Float> = NO_CLIP
    ) -> RenderInstance {
        RenderInstance(
            rect: rect,
            radii: radii,
            fill: fill,
            border: border,
            params: SIMD4<Float>(borderWidth, KIND_RECT, 0, 1),
            uv: .zero,
            clip: clip,
            fade: .zero
        )
    }

    @Test("HalfRounding and NeedsGpu gate every unsupported scene variant cleanly")
    func halfRoundingAndNeedsGpu() {
        #expect(HalfRounding.ofVendor(0x8086) == .towardZero)
        #expect(HalfRounding.ofVendor(0x10de) == .towardZero)
        #expect(HalfRounding.ofVendor(0x106b) == .towardZero)
        #expect(HalfRounding.ofVendor(0x1002) == .towardZero)

        // Subnormal + normal f16 rounding parity
        #expect(CpuBootRaster.f16(1.0, .nearestEven) == 1.0)
        #expect(CpuBootRaster.f16(0.5, .towardZero) == 0.5)
        let small: Float = 1.0 / 16384.0
        #expect(CpuBootRaster.f16(small, .nearestEven) > 0.0)

        var s = CpuBootScene(instances: [], size: (32, 32))
        #expect(s.half == .towardZero)
        #expect(s.needsGpu() == nil)

        s.srgbBlend = false
        #expect(s.needsGpu() == .linearBlend)
        s.srgbBlend = true

        s.nativeSurfaces = true
        #expect(s.needsGpu() == .nativeSurfaces)
        s.nativeSurfaces = false

        s.smoothing = .slug
        #expect(s.needsGpu() == .slugText)
        s.smoothing = .classic
        #expect(s.needsGpu() == nil)
        s.smoothing = nil

        // Compositor without KIND_EFFECT draws cleanly on CPU; KIND_EFFECT without compositor draws nothing on CPU.
        s.compositor = true
        #expect(s.needsGpu() == nil)
        s.compositor = false

        s.instances = [RenderInstance(rect: .zero, params: SIMD4<Float>(0, KIND_EFFECT, 0, 1), clip: NO_CLIP)]
        #expect(s.needsGpu() == nil)
        s.compositor = true
        #expect(s.needsGpu() == .effect)
        s.compositor = false

        var rotLayer = RenderInstance.beginLayer(bounds: SIMD4<Float>(0, 0, 10, 10), clip: NO_CLIP)
        rotLayer.border.y = 0.5
        s.instances = [rotLayer, .endLayer()]
        #expect(s.needsGpu() == .rotatedLayer)

        s.instances = [.beginLayer(bounds: SIMD4<Float>(0, 0, 10, 10), clip: NO_CLIP, spec: LayerSpec(blur: 0.01)), .endLayer()]
        #expect(s.needsGpu() == .filteredLayer)

        s.instances = [
            .beginLayer(bounds: SIMD4<Float>(0, 0, 10, 10), clip: NO_CLIP),
            RenderInstance(rect: SIMD4<Float>(0, 0, 10, 10), params: SIMD4<Float>(4, KIND_BACKDROP_BLUR, 0, 1), clip: NO_CLIP),
            .endLayer(),
        ]
        #expect(s.needsGpu() == .backdropInLayer)

        // Outline glyphs: radii.w > 0 requires GPU when outlines is nil or Slug ray mode (border.w == 1.0)
        s.outlines = nil
        s.instances = [RenderInstance(rect: SIMD4<Float>(0, 0, 12, 12), radii: SIMD4<Float>(0, 0, 0, 1), params: SIMD4<Float>(0, KIND_GLYPH, 0, 1), clip: NO_CLIP)]
        #expect(s.needsGpu() == .outlineGlyph)

        s.outlines = OutlineStore()
        #expect(s.needsGpu() == nil)
        s.instances = [RenderInstance(rect: SIMD4<Float>(0, 0, 12, 12), radii: SIMD4<Float>(0, 0, 0, 1), border: SIMD4<Float>(0, 0, 0, 1.0), params: SIMD4<Float>(0, KIND_GLYPH, 0, 1), clip: NO_CLIP)]
        #expect(s.needsGpu() == .outlineGlyph)

        // Fractional & out-of-range kinds rejected
        s.instances = [RenderInstance(rect: .zero, params: SIMD4<Float>(0, 1.5, 0, 1), clip: NO_CLIP)]
        #expect(s.needsGpu() == .unknownKind(1))
        s.instances = [RenderInstance(rect: .zero, params: SIMD4<Float>(0, 14.0, 0, 1), clip: NO_CLIP)]
        #expect(s.needsGpu() == .unknownKind(14))
    }

    @Test("CpuBootPool and CpuPainter release cleanly without worker retain cycles")
    func cpuBootPoolReleasesWithoutRetainCycle() throws {
        weak var weakPool: CpuBootPool?
        weak var weakPainter: CpuPainter?
        do {
            let pool = CpuBootPool(threads: 3)
            weakPool = pool
            pool.run(extra: 2) {}

            let painter = CpuPainter(threads: 3)
            weakPainter = painter
            var target = CpuBootTarget(width: 128, height: 64)
            let scene = CpuBootScene(instances: [rect(SIMD4<Float>(0, 0, 64, 32), fill: SIMD4<Float>(1, 0, 0, 1))], size: (128, 64))
            _ = try painter.paint(scene, into: &target)
        }
        #expect(weakPool == nil)
        #expect(weakPainter == nil)
    }

    @Test("RCB1 recording encode and decode round-trips scene and paints identical pixels")
    func rcb1RecordingRoundTrip() throws {
        let imgData: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255,
        ]
        let glyphPage = [UInt8](repeating: 200, count: 16 * 16)
        let scene = CpuBootScene(
            instances: [
                rect(SIMD4<Float>(2, 2, 20, 12), fill: SIMD4<Float>(0.2, 0.4, 0.8, 1.0), radii: SIMD4<Float>(4, 4, 4, 4)),
                RenderInstance(
                    rect: SIMD4<Float>(6, 6, 4, 4),
                    fill: SIMD4<Float>(1, 1, 1, 1),
                    params: SIMD4<Float>(0, KIND_GLYPH, 0, 1),
                    uv: SIMD4<Float>(0, 0, 4, 4),
                    clip: NO_CLIP
                ),
                RenderInstance(
                    rect: SIMD4<Float>(20, 4, 8, 8),
                    fill: SIMD4<Float>(0, 0, 0, 1),
                    params: SIMD4<Float>(0, KIND_IMAGE, 0, 1),
                    uv: SIMD4<Float>(0, 0, 2, 2),
                    clip: NO_CLIP
                ),
            ],
            glyphPages: [glyphPage],
            glyphPageWidth: 16,
            glyphPageHeight: 16,
            images: [CpuBootImage(width: 2, data: imgData)],
            size: (32, 24),
            clear: SIMD4<Float>(0.05, 0.05, 0.08, 1.0),
            lcd: true
        )

        let bytes = CpuBootRecord.encode(scene)
        #expect(Array(bytes.prefix(4)) == Array("RCB1".utf8))
        let rec = try #require(CpuBootRecord.decode(bytes))
        #expect(rec.size == (32, 24))
        #expect(rec.lcd == true)
        #expect(rec.instances.count == 3)

        var t1 = CpuBootTarget(width: 32, height: 24)
        var t2 = CpuBootTarget(width: 32, height: 24)
        _ = try CpuBoot.paint(scene, into: &t1, threads: 1)
        _ = try CpuBoot.paint(rec.scene(), into: &t2, threads: 2)
        #expect(t1.pixels == t2.pixels)
    }

    @Test("CpuPainter performs dirty-tile, recolour fast-path, and scroll row moves accurately")
    func cpuPainterIncrementalDamageAndScroll() throws {
        let w = 256
        let h = 256
        func makeListScene(scrollY: Float, color0: SIMD4<Float>) -> CpuBootScene {
            var insts: [RenderInstance] = [
                rect(SIMD4<Float>(0, 0, Float(w), Float(h)), fill: SIMD4<Float>(0.08, 0.09, 0.12, 1.0))
            ]
            // 20 rows inside a scroll clip [0, 16, 256, 240]
            let clip = SIMD4<Float>(0, 16, Float(w), 240)
            for row in 0..<20 {
                let y = 16 + Float(row) * 20.0 + scrollY
                let c = (row == 0) ? color0 : SIMD4<Float>(0.3, 0.5, 0.9, 1.0)
                insts.append(rect(SIMD4<Float>(16, y, 200, 12), fill: c, clip: clip))
            }
            return CpuBootScene(instances: insts, size: (w, h), clear: SIMD4<Float>(0, 0, 0, 1))
        }

        let painter = CpuPainter(threads: 2)
        var incrementalTarget = CpuBootTarget(width: w, height: h)
        let s0 = makeListScene(scrollY: 0, color0: SIMD4<Float>(0.9, 0.2, 0.2, 1.0))
        let p0 = try painter.paint(s0, into: &incrementalTarget)
        #expect(p0.dirtyTiles == p0.tiles)

        // Identical second frame touches 0 tiles
        let p1 = try painter.paint(s0, into: &incrementalTarget)
        #expect(p1.dirtyTiles == 0)
        #expect(p1.rects.isEmpty)

        // Recolour one row -> recolour fast path repaints only affected tiles
        let sRecolour = makeListScene(scrollY: 0, color0: SIMD4<Float>(0.2, 0.9, 0.3, 1.0))
        let pRecolour = try painter.paint(sRecolour, into: &incrementalTarget)
        #expect(pRecolour.dirtyTiles > 0 && pRecolour.dirtyTiles < pRecolour.tiles)
        var refRecolour = CpuBootTarget(width: w, height: h)
        _ = try CpuBoot.paint(sRecolour, into: &refRecolour, threads: 1)
        #expect(incrementalTarget.pixels == refRecolour.pixels)

        // Whole-pixel scroll by +8px triggers scroll plan/move and matches full fresh paint byte-for-byte
        let sScrolled = makeListScene(scrollY: 8, color0: SIMD4<Float>(0.2, 0.9, 0.3, 1.0))
        let pScroll = try painter.paint(sScrolled, into: &incrementalTarget)
        #expect(pScroll.scrolled != nil)
        var refScroll = CpuBootTarget(width: w, height: h)
        _ = try CpuBoot.paint(sScrolled, into: &refScroll, threads: 1)
        #expect(incrementalTarget.pixels == refScroll.pixels)
    }

    #if canImport(Metal)
    @Test("CpuBoot matches Metal GPU Bgra8Unorm rendering across primitives, layers, and backdrop blur")
    func cpuBootMatchesMetalGpu() throws {
        let renderer = try MetalRenderer()
        let w = 128
        let h = 96

        let seg = RenderInstance(
            rect: SIMD4<Float>(8, 70, 48, 20),
            fill: SIMD4<Float>(1.0, 0.6, 0.1, 1.0),
            border: SIMD4<Float>(12, 74, 52, 84),
            params: SIMD4<Float>(3.0, KIND_SEGMENT, 1.0, 1.0),
            clip: NO_CLIP
        )
        let tri = RenderInstance(
            rect: SIMD4<Float>(68, 66, 28, 22),
            radii: SIMD4<Float>(68, 88, 96, 88),
            fill: SIMD4<Float>(0.1, 0.9, 0.5, 1.0),
            border: SIMD4<Float>(82, 66, 0, 0),
            params: SIMD4<Float>(1, KIND_TRIANGLE, 0, 1),
            clip: NO_CLIP
        )
        let backdrop = RenderInstance(
            rect: SIMD4<Float>(24, 16, 48, 36),
            radii: SIMD4<Float>(8, 8, 8, 8),
            fill: SIMD4<Float>(0, 0, 0, 1),
            params: SIMD4<Float>(6.0, KIND_BACKDROP_BLUR, 0, 1),
            clip: NO_CLIP
        )

        let instances: [RenderInstance] = [
            rect(SIMD4<Float>(0, 0, Float(w), Float(h)), fill: SIMD4<Float>(0.1, 0.12, 0.16, 1.0)),
            rect(SIMD4<Float>(12, 12, 40, 40), fill: SIMD4<Float>(0.9, 0.2, 0.3, 1.0), radii: SIMD4<Float>(-8, -8, -8, -8), border: SIMD4<Float>(1, 1, 1, 0.8), borderWidth: 2),
            backdrop,
            .beginLayer(bounds: SIMD4<Float>(72, 12, 40, 40), clip: NO_CLIP, spec: LayerSpec(opacity: 0.65, clipRadius: 10)),
            rect(SIMD4<Float>(72, 12, 40, 40), fill: SIMD4<Float>(0.2, 0.7, 1.0, 1.0)),
            .endLayer(),
            seg,
            tri,
        ]

        let scene = CpuBootScene(
            instances: instances,
            size: (w, h),
            clear: SIMD4<Float>(0, 0, 0, 1),
            srgbBlend: true
        )
        var cpuTarget = CpuBootTarget(width: w, height: h)
        let report = try CpuBoot.paint(scene, into: &cpuTarget, threads: 2)
        #expect(report.tiles > 0)
        #expect(report.blurNs > 0)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: desc),
              let cmdBuf = renderer.commandQueue.makeCommandBuffer() else {
            throw MetalRenderer.RendererError.metalUnavailable
        }
        let frame = RenderFrame(
            width: w,
            height: h,
            srgbBlend: true,
            clearColor: SIMD4<Float>(0, 0, 0, 1),
            instances: instances
        )
        renderer.drawRange(frame: frame, into: tex, commandBuffer: cmdBuf)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        var gpuBGRA = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&gpuBGRA, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let drift = CpuBootDriftMeter.drift(
            .bgra(cpuTarget.pixels, width: w, height: h),
            .bgra(gpuBGRA, width: w, height: h)
        )
        #expect(drift.pixels == w * h)
        #expect(drift.overTwo == 0, "CPU vs GPU drift exceeded 2/255: max=\(drift.max) overTwo=\(drift.overTwo)")
    }
    #endif
}
