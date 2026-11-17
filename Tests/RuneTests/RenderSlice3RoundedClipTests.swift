import Foundation
import Testing
@testable import Rune
import RuneMotion

#if canImport(Metal) && canImport(QuartzCore)
import Metal
#endif

@Suite("Slice 3 Rounded Clip Parity Tests (rounded_clip_tests.rs)")
struct RenderSlice3RoundedClipTests {
    /// Circle-corner coverage oracle, independent of the shader's rounded-box distance expression (`rounded_clip_tests.rs:100`).
    private func mask(_ x: Float, _ y: Float, _ rect: [Float], _ radius: Float) -> Float {
        let cx = min(max(x, rect[0] + radius), rect[2] - radius)
        let cy = min(max(y, rect[1] + radius), rect[3] - radius)
        let corner = min(max(radius + 0.5 - hypotf(x - cx, y - cy), 0.0), 1.0)
        return corner
            * min(max(x - rect[0] + 0.5, 0.0), 1.0)
            * min(max(rect[2] - x + 0.5, 0.0), 1.0)
            * min(max(y - rect[1] + 0.5, 0.0), 1.0)
            * min(max(rect[3] - y + 0.5, 0.0), 1.0)
    }

    #if canImport(Metal)
    private func drawRaw(renderer: MetalRenderer, frame: RenderFrame) throws -> [UInt8] {
        let w = max(1, frame.width)
        let h = max(1, frame.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: frame.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb,
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
        renderer.drawRange(frame: frame, into: tex, commandBuffer: cmdBuf)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        #expect(cmdBuf.error == nil)
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bgra, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            rgba[i] = bgra[i + 2]
            rgba[i + 1] = bgra[i + 1]
            rgba[i + 2] = bgra[i]
            rgba[i + 3] = bgra[i + 3]
        }
        return rgba
    }

    #endif

    // 1. #127 (`rounded_clip_tests.rs:6`)
    @Test("packed_clip_radii_boundaries_and_fade_lanes_do_not_collide")
    func packedClipRadiiBoundariesAndFadeLanesDoNotCollide() {
        let rect = SIMD4<Float>(0.0, 0.0, 2000.0, 2000.0)
        let cases: [(SIMD4<Float>, SIMD4<Float>)] = [
            (SIMD4<Float>(0.0, 0.24, 12.26, 63.5), SIMD4<Float>(0.0, 0.0, 12.5, 63.5)),
            (SIMD4<Float>(0.0, 63.6, 127.0, 254.0), SIMD4<Float>(0.0, 64.0, 128.0, 254.0)),
            (SIMD4<Float>(0.0, 256.0, 500.0, 2000.0), SIMD4<Float>(0.0, 254.0, 254.0, 254.0)),
            (SIMD4<Float>(-1.0, -12.5, 0.0, -63.5), SIMD4<Float>(-1.0, -12.5, 0.0, -63.5)),
        ]
        for (radii, want) in cases {
            #expect(unpackClipRadii(packClipRadii(clip: rect, radii: radii)) == want)
        }
        for r: Float in [0.0, 0.125, 63.75, 254.5, 999.0, -999.0] {
            #expect(unpackClipRadii(packClipRadii(clip: rect, radii: SIMD4<Float>(repeating: r))) == SIMD4<Float>(repeating: r))
        }
        for r: Float in [1e30, -1e30, .infinity] {
            let word = packClipRadii(clip: SIMD4<Float>(0.0, 0.0, 1e35, 1e35), radii: SIMD4<Float>(repeating: r))
            #expect((word & 0x6000_0000) != 0x6000_0000, "uniform radius cannot become a tag")
            let unpacked = unpackClipRadii(word)
            for v in [unpacked.x, unpacked.y, unpacked.z, unpacked.w] {
                #expect(v.isFinite && abs(v) > 1e18)
            }
        }
        let fade = packFade(width: SIMD4<Float>(repeating: 65504.0), origin: rect, clip: rect)
        #expect(fade.w == 0, "even maximal fade widths never occupy the radius word")
    }

    // 2. #129 (`rounded_clip_tests.rs:29`)
    @Test("rounded_clip_follows_paint_radii_unless_explicitly_overridden")
    func roundedClipFollowsPaintRadiiUnlessExplicitlyOverridden() {
        for (mode, want): (UInt8, Float) in [(0, 12.0), (1, 4.0), (2, 12.0)] {
            let rt = Runtime<UInt8>(state: mode, viewport: Vec2(80, 40), pixelScale: 1.0) { m, _ in
                var card: El<UInt8> = el().size(80, 40).corners(12, 12, 12, 12).clipRounded(4)
                if m == 1 {
                    card = card.clipCorners(Corners(4, 4, 4, 4))
                } else if m == 2 {
                    card = card.clipCorners(Corners(4, 4, 4, 4)).clipRounded(8)
                }
                return card.child(el().size(80, 40).bg(.white))
            }
            let rf = rt.renderFrame(at: 0.0)
            #expect(rf.instances.contains { unpackClipRadii($0.fade.w) == SIMD4<Float>(repeating: want) })
        }
    }

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // 3. #131 (`rounded_clip_tests.rs:47`)
    @Test("per_corner_video_clip_matches_the_primitive_mask")
    func perCornerVideoClipMatchesThePrimitiveMask() throws {
        typealias State = (surface: NativeSurface, video: Bool, continuous: Bool)
        let surface = NativeSurface()
        let byteFrame = try ByteFrame(width: 1, height: 1, format: .bgra, color: .srgb, planes: [Data(repeating: 255, count: 4)])
        try surface.pushBytes(byteFrame, frameId: 1)

        let renderer = try OffscreenGPURenderer()
        for continuous in [false, true] {
            var outs: [[UInt8]] = []
            for video in [false, true] {
                let rt = Runtime<State>(state: (surface, video, continuous), viewport: Vec2(64, 48), pixelScale: 1.0) { s, _ in
                    var card: El<State> = el().size(48, 32).absolute(x: 8, y: 8).corners(12, 4, 0, 8)
                    if s.continuous { card = card.continuousCorners() }
                    if s.video {
                        return el().size(64, 48).child(
                            card.clipRounded(2).child(
                                el().size(64, 48).absolute(x: -8, y: -8).nativeSurface(s.surface, .fill)
                            )
                        )
                    } else {
                        return el().size(64, 48).child(card.clipSoft(0).bg(.white))
                    }
                }
                rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                rt.srgbBlend = true
                let rf = rt.renderFrame(at: 0.0)
                let frame = try renderer.renderOffscreen(rf)
                outs.append(frame.rgba)
            }
            for byte in 0..<outs[0].count {
                let a = outs[0][byte]
                let b = outs[1][byte]
                #expect(abs(Int(a) - Int(b)) <= 1, "continuous=\(continuous) byte=\(byte) primitive=\(a) video=\(b)")
            }
        }
    }

    #endif

    // 4. #132 (`rounded_clip_tests.rs:83`)
    @Test("raised_children_keep_the_ancestors_per_corner_clip")
    func raisedChildrenKeepTheAncestorsPerCornerClip() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(64, 48), pixelScale: 1.0) { _, _ in
            el().size(64, 48).child(
                el().size(48, 32).absolute(x: 8, y: 8)
                    .corners(12, 4, 0, 8).continuousCorners().clipRounded(2).opacity(0.8)
                    .child(el().size(64, 48).absolute(x: -8, y: -8).bg(.white).raise())
            )
        }
        let rf = rt.renderFrame(at: 0.0)
        let masks = rf.instances.filter { $0.params.y == KIND_LAYER && $0.fade.w != 0 }
        #expect(!masks.isEmpty)
        for m in masks {
            #expect(m.clip == SIMD4<Float>(8.0, 8.0, 56.0, 40.0))
            #expect(unpackClipRadii(m.fade.w) == SIMD4<Float>(-12.0, -4.0, 0.0, -8.0))
        }
    }

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // 5. #133 (`rounded_clip_tests.rs:109`)
    @Test("rounded_clip_direct_nested_and_rectangular_intersections")
    func roundedClipDirectNestedAndRectangularIntersections() throws {
        #expect(MemoryLayout<RenderInstance>.stride == 128)
        let renderer = try OffscreenGPURenderer()
        for mode in 0..<3 {
            let rt = Runtime<Int>(state: mode, viewport: Vec2(64, 48), pixelScale: 1.0) { m, _ in
                let white: El<Int> = el().size(100, 100).absolute(x: -30, y: -30).bg(.white)
                let child: El<Int> = (m == 0)
                    ? white
                    : el().size(40, 48).absolute(x: 14, y: -8).clipRounded(10).child(white)
                let capsule: El<Int> = el().size(48, 32).absolute(x: 8, y: 8).clipRounded(16).child(child)
                if m == 2 {
                    return el().size(64, 48).child(
                        el().size(40, 48).absolute(x: 24, y: 0).clipSoft(0).child(
                            el().size(64, 48).absolute(x: -24, y: 0).child(capsule)
                        )
                    )
                } else {
                    return el().size(64, 48).child(capsule)
                }
            }
            rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
            rt.srgbBlend = true
            let rf = rt.renderFrame(at: 0.0)
            let frame = try renderer.renderOffscreen(rf)
            #if canImport(Metal)
            if mode == 0 {
                #expect(renderer.metal.layerStats().extraPasses == 0, "ordinary rounded clip stays direct")
            }
            #endif
            for y in 0..<48 {
                for x in 0..<64 {
                    let px = Float(x) + 0.5
                    let py = Float(y) + 0.5
                    var a = mask(px, py, [8.0, 8.0, 56.0, 40.0], 16.0)
                    if mode > 0 { a *= mask(px, py, [22.0, 0.0, 62.0, 48.0], 10.0) }
                    if mode == 2 && x < 24 { a = 0.0 }
                    let got = frame.rgba[(y * 64 + x) * 4 + 3]
                    let want = UInt8((a * 255.0).rounded())
                    #expect(abs(Int(got) - Int(want)) <= 1, "mode=\(mode) (\(x),\(y)): \(got) vs \(a)")
                }
            }
        }
    }

    // 6. #134 (`rounded_clip_tests.rs:144`)
    @Test("rounded_clip_blurred_exiting_chip_stays_inside_capsule")
    func roundedClipBlurredExitingChipStaysInsideCapsule() throws {
        typealias State = (clipped: Bool, offset: Live<Vec2>)
        func makeRt(clipped: Bool, live: Live<Vec2>) -> Runtime<State> {
            let rt = Runtime<State>(state: (clipped, live), viewport: Vec2(448, 88), pixelScale: 2.0) { s, _ in
                var capsule: El<State> = el().size(400, 40).absolute(x: 24, y: 24)
                if s.clipped { capsule = capsule.clipRounded(20) }
                return el().size(448, 88).child(
                    capsule.child(
                        el().size(72, 28).absolute(x: 370, y: 6)
                            .liveOffset(s.offset.binding)
                            .opacity(0.65)
                            .blur(1.5)
                            .rounded(8)
                            .bg(Color(r: 0.06, g: 0.32, b: 1.0, a: 1.0))
                            .child(text("Leaving").color(.white).absolute(x: 8, y: 6))
                    )
                )
            }
            rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
            rt.srgbBlend = true
            return rt
        }
        let livePlain = Live<Vec2>(.zero)
        let liveClipped = Live<Vec2>(.zero)
        let plain = makeRt(clipped: false, live: livePlain)
        let clipped = makeRt(clipped: true, live: liveClipped)
        let renderer = try OffscreenGPURenderer()

        for offset: Float in [0.0, 26.0, 32.0] {
            _ = livePlain.set(Vec2(offset, 0.0))
            _ = liveClipped.set(Vec2(offset, 0.0))
            let rfPlain = plain.renderFrame(at: 0.0)
            let rfClipped = clipped.renderFrame(at: 0.0)
            let outPlain = try renderer.renderOffscreen(rfPlain).rgba
            let outClipped = try renderer.renderOffscreen(rfClipped).rgba

            var retained = false
            var removed = false
            for y in 0..<176 {
                for x in 0..<896 {
                    let a = mask(Float(x) + 0.5, Float(y) + 0.5, [48.0, 48.0, 848.0, 128.0], 40.0)
                    let at = (y * 896 + x) * 4
                    let want = UInt8((Float(outPlain[at + 3]) * a).rounded())
                    #expect(abs(Int(outClipped[at + 3]) - Int(want)) <= 1, "offset=\(offset) (\(x),\(y))")
                    if a == 0.0 {
                        #expect(Array(outClipped[at..<(at + 4)]) == [0, 0, 0, 0])
                        if outPlain[at + 3] > 0 { removed = true }
                    }
                    if a == 1.0 && outClipped[at + 3] > 0 { retained = true }
                }
            }
            #expect(removed && retained, "clip removes the halo but keeps off-wall source contributions")
            let layer = try #require(rfClipped.instances.first { $0.params.y == KIND_LAYER && $0.params.z > 0.0 })
            #expect(layer.clip == SIMD4<Float>(48.0, 48.0, 848.0, 128.0))
            #expect(Float(bitPattern: layer.fade.w) == 40.0)
            #expect(layer.uv == .zero)
            #expect(layer.radii == .zero)
        }
    }

    // 7. #135 (`rounded_clip_tests.rs:202`)
    @Test("rounded_clip_preserves_every_primitive_lane_and_feathers")
    func roundedClipPreservesEveryPrimitiveLaneAndFeathers() throws {
        let renderer = try OffscreenGPURenderer()
        var glyphTexels = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<48 {
            for x in 0..<64 {
                glyphTexels[y * 64 + x] = 128
            }
        }
        let glyphs = R8Atlas(width: 64, height: 64, texels: glyphTexels)
        let images = RGBA8Atlas(width: 1, height: 1, texels: [80, 160, 240, 200])

        for kind in 0..<8 {
            var instance = RenderInstance(
                rect: SIMD4<Float>(0, 0, 64, 48),
                radii: SIMD4<Float>(3, 5, 7, 9),
                fill: SIMD4<Float>(0.2, 0.4, 0.6, 0.8),
                border: SIMD4<Float>(0.8, 0.1, 0.2, 0.9),
                params: SIMD4<Float>(2.0, Float(kind), 2.0, 1.4),
                uv: .zero,
                clip: SIMD4<Float>(8, 8, 56, 40),
                fade: packFade(
                    width: SIMD4<Float>(1, 2, 3, 4),
                    origin: SIMD4<Float>(8, 8, 56, 40),
                    clip: SIMD4<Float>(8, 8, 56, 40)
                )
            )
            switch kind {
            case 2: // KIND_GLYPH
                instance.params.x = 0.0
                instance.radii = .zero
                instance.uv = SIMD4<Float>(0, 0, 64, 48)
            case 3: // KIND_INSET
                instance.uv = SIMD4<Float>(4, 6, 0, 0)
                instance.params.x = 12.0
            case 4: // KIND_GRADIENT
                instance.uv = SIMD4<Float>(0.8, 0.2, 0.3, 1.0)
            case 5: // KIND_SEGMENT
                instance.radii = SIMD4<Float>(4, 24, 60, 24)
                instance.params.x = 24.0
                instance.params.z = 1.0
            case 6: // KIND_TRIANGLE
                instance.radii = SIMD4<Float>(-20, -20, 100, -20)
                instance.uv = SIMD4<Float>(32, 100, 0, 0)
                instance.params.x = 7.0
            case 7: // KIND_IMAGE
                instance.uv = SIMD4<Float>(0, 0, 1, 1)
                instance.params.x = 0.0
                instance.params.z = 0.0
            default:
                break
            }

            let plainFrame = RenderFrame(
                width: 64,
                height: 48,
                srgbBlend: true,
                clearColor: .zero,
                glyphs: glyphs,
                glyphGeneration: UInt64(kind * 2 + 1),
                images: images,
                imageRevision: UInt64(kind * 2 + 1),
                instances: [instance]
            )
            let plain = try renderer.renderOffscreen(plainFrame).rgba

            instance.roundClip(16.0)
            let clippedFrame = RenderFrame(
                width: 64,
                height: 48,
                srgbBlend: true,
                clearColor: .zero,
                glyphs: glyphs,
                glyphGeneration: UInt64(kind * 2 + 2),
                images: images,
                imageRevision: UInt64(kind * 2 + 2),
                instances: [instance]
            )
            let clipped = try renderer.renderOffscreen(clippedFrame).rgba
            #if canImport(Metal)
            #expect(renderer.metal.layerStats().extraPasses == 0)
            #endif

            var cut = false
            func toPremul(_ rgba: [UInt8], at: Int) -> [Float] {
                let a = Float(rgba[at + 3]) / 255.0
                return [Float(rgba[at]) * a, Float(rgba[at + 1]) * a, Float(rgba[at + 2]) * a, Float(rgba[at + 3])]
            }
            for y in 0..<48 {
                for x in 0..<64 {
                    let a = mask(Float(x) + 0.5, Float(y) + 0.5, [8, 8, 56, 40], 16.0)
                    let at = (y * 64 + x) * 4
                    let pPlain = toPremul(plain, at: at)
                    let pClip = toPremul(clipped, at: at)
                    for c in 0..<4 {
                        let want = UInt8((pPlain[c] * a).rounded())
                        let got = UInt8(pClip[c].rounded())
                        #expect(abs(Int(got) - Int(want)) <= 1, "kind=\(kind) (\(x),\(y)) ch=\(c)")
                    }
                    if plain[at + 3] > clipped[at + 3] { cut = true }
                }
            }
            #expect(cut, "kind \(kind) exercised a rounded corner")
        }
    }

    // 8. #136 (`rounded_clip_tests.rs:249`)
    @Test("rounded_clip_native_video_inherits_capsule_without_a_layer")
    func roundedClipNativeVideoInheritsCapsuleWithoutALayer() throws {
        let renderer = try OffscreenGPURenderer()
        let surface = NativeSurface()
        let byteFrame = try ByteFrame(width: 1, height: 1, format: .bgra, color: .srgb, planes: [Data(repeating: 255, count: 4)])
        try surface.pushBytes(byteFrame, frameId: 1)

        let rt = Runtime<NativeSurface>(state: surface, viewport: Vec2(64, 48), pixelScale: 1.0) { s, _ in
            el().size(64, 48).child(
                el().size(48, 32).absolute(x: 8, y: 8).clipRounded(16).child(
                    el().size(64, 48).absolute(x: -8, y: -8).nativeSurface(s, .fill)
                )
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = true
        let rf = rt.renderFrame(at: 0.0)
        let out = try renderer.renderOffscreen(rf).rgba
        #if canImport(Metal)
        #expect(renderer.metal.layerStats().extraPasses == 0)
        #endif
        for y in 0..<48 {
            for x in 0..<64 {
                let a = mask(Float(x) + 0.5, Float(y) + 0.5, [8, 8, 56, 40], 16.0)
                let want = UInt8((a * 255.0).rounded())
                #expect(abs(Int(out[(y * 64 + x) * 4 + 3]) - Int(want)) <= 1)
            }
        }
    }

    // 9. #137 (`rounded_clip_tests.rs:274`)
    @Test("rounded_clip_live_truncated_text_preserves_corner_centres")
    func roundedClipLiveTruncatedTextPreservesCornerCentres() throws {
        typealias State = (clipped: Bool, text: LiveText, truncate: Bool)
        let renderer = try OffscreenGPURenderer()
        for scale: Float in [1.0, 2.0] {
            for truncate in [false, true] {
                let value = LiveText("MMMMMMMM")
                func makeRt(clipped: Bool) -> Runtime<State> {
                    let rt = Runtime<State>(state: (clipped, value, truncate), viewport: Vec2(64, 48), pixelScale: scale) { s, _ in
                        var capsule: El<State> = el().size(48, 32).absolute(x: 8, y: 8)
                        if s.clipped { capsule = capsule.clipRounded(16) }
                        var label: El<State> = liveText(s.text)
                            .size(44, 32)
                            .absolute(x: 2, y: -2)
                            .font(TextStyle(size: 28, weight: 700))
                            .color(.white)
                        if s.truncate { label = label.truncateFade() }
                        return el().size(64, 48).child(capsule.child(label))
                    }
                    rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                    rt.srgbBlend = true
                    return rt
                }
                let plain = makeRt(clipped: false)
                let clipped = makeRt(clipped: true)
                let w = Int((64.0 * scale).rounded())
                let h = Int((48.0 * scale).rounded())

                for words in ["MMMMMMMM", "WW", "MMMMMMMMMMMM"] {
                    _ = value.set(words)
                    let outPlain = try renderer.renderOffscreen(plain.renderFrame(at: 0.0)).rgba
                    let outClipped = try renderer.renderOffscreen(clipped.renderFrame(at: 0.0)).rgba
                    var cut = false
                    var kept = false
                    for y in 0..<h {
                        for x in 0..<w {
                            let a = mask(Float(x) + 0.5, Float(y) + 0.5, [8 * scale, 8 * scale, 56 * scale, 40 * scale], 16.0 * scale)
                            let at = (y * w + x) * 4 + 3
                            let want = UInt8((Float(outPlain[at]) * a).rounded())
                            #expect(abs(Int(outClipped[at]) - Int(want)) <= 1, "scale=\(scale) truncate=\(truncate) words=\(words) (\(x),\(y))")
                            if outPlain[at] > outClipped[at] { cut = true }
                            if outClipped[at] > 0 { kept = true }
                        }
                    }
                    #expect(cut && kept, "exercise glyph coverage inside and outside the corner")
                }
            }
        }
    }

    // 10. #138 (`rounded_clip_tests.rs:318`)
    @Test("live_text_clear_of_rounded_corners_draws_without_a_layer")
    func liveTextClearOfRoundedCornersDrawsWithoutALayer() throws {
        typealias State = (clipped: Bool, text: LiveText)
        let renderer = try OffscreenGPURenderer()
        let bgCol = Color.oklch(0.25, 0.04, 260.0)
        for scale: Float in [1.0, 2.0] {
            let value = LiveText("0000")
            func makeRt(clipped: Bool) -> Runtime<State> {
                let rt = Runtime<State>(state: (clipped, value), viewport: Vec2(136, 80), pixelScale: scale) { s, _ in
                    var card: El<State> = el().size(120, 64).absolute(x: 8, y: 8).rounded(16).bg(bgCol)
                    if s.clipped { card = card.clipRounded(16) }
                    let label: El<State> = liveText(s.text)
                        .size(80, 24)
                        .absolute(x: 10, y: 8)
                        .font(TextStyle(size: 20, weight: 700))
                        .color(.white)
                    return el().size(136, 80).child(card.child(label))
                }
                rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                rt.srgbBlend = true
                return rt
            }
            let plain = makeRt(clipped: false)
            let clipped = makeRt(clipped: true)
            let w = Int((136.0 * scale).rounded())
            let x0 = Int(18.0 * scale)
            let y0 = Int(16.0 * scale)
            let x1 = Int(98.0 * scale)
            let y1 = Int(40.0 * scale)

            for words in ["0000", "8888", "WWWW"] {
                _ = value.set(words)
                let rfPlain = plain.renderFrame(at: 0.0)
                let rfClipped = clipped.renderFrame(at: 0.0)
                #expect(rfPlain.instances.allSatisfy { $0.params.y != KIND_LAYER }, "scale=\(scale) words=\(words): no layer")
                #expect(rfClipped.instances.allSatisfy { $0.params.y != KIND_LAYER }, "scale=\(scale) words=\(words): no layer")
                let outPlain = try renderer.renderOffscreen(rfPlain).rgba
                let outClipped = try renderer.renderOffscreen(rfClipped).rgba
                var lit = false
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let at = (y * w + x) * 4
                        for c in 0..<4 {
                            #expect(abs(Int(outPlain[at + c]) - Int(outClipped[at + c])) <= 1, "scale=\(scale) words=\(words) (\(x),\(y))")
                        }
                        if outClipped[at] > 200 { lit = true }
                    }
                }
                #expect(lit, "the glyphs drew")
            }
        }
    }

    #endif

    // 11a. #139a (`rounded_clip_tests.rs:358`)
    @Test("rounded_clip_and_dissolve_follow_retained_presence")
    func roundedClipAndDissolveFollowRetainedPresence() {
        let rt = Runtime<Bool>(state: true, viewport: Vec2(80, 40), pixelScale: 2.0) { show, _ in
            var container: El<Bool> = el().size(80, 40).clipRounded(20).dissolve()
            if show {
                container = container.child(
                    el().key("chip").size(40, 28).bg(.white).transition(.blurReplace())
                )
            }
            return container
        }
        let rf0 = rt.renderFrame(at: 0.0)
        #expect(rf0.instances.allSatisfy { $0.params.y != KIND_LAYER })
        rt.update(at: 0.01) { s, tx in
            s = false
            tx.animated()
        }
        _ = rt.renderFrame(at: 0.01)
        let rfMid = rt.renderFrame(at: 0.05)
        #expect(rfMid.instances.contains { $0.params.y == KIND_LAYER && $0.params.x == 1.0 && Float(bitPattern: $0.fade.w) == 40.0 })
        #expect(rfMid.instances.contains { $0.params.y == KIND_LAYER && $0.params.z > 0.0 })
        var t = 0.05
        for _ in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.renderFrame(at: t)
        }
        let rfDone = rt.renderFrame(at: t + 1.0)
        #expect(rfDone.instances.allSatisfy { $0.params.y != KIND_LAYER })
    }

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // 11b. #139b (`rounded_clip_tests.rs:375`)
    @Test("rounded_clip_leaves_central_scroll_rectangles_on_the_direct_path")
    func roundedClipLeavesCentralScrollRectanglesOnTheDirectPath() throws {
        typealias State = (rounded: Bool, horizontal: Bool)
        let renderer = try OffscreenGPURenderer()
        for horizontal in [false, true] {
            var frames: [[UInt8]] = []
            for rounded in [false, true] {
                let rt = Runtime<State>(state: (rounded, horizontal), viewport: Vec2(96, 64), pixelScale: 1.0) { s, _ in
                    var capsule: El<State> = el().size(80, 48).absolute(x: 8, y: 8)
                    if s.rounded { capsule = capsule.clipRounded(16) }
                    let (x, y, w, h): (Float, Float, Float, Float) = s.horizontal ? (0, 16, 80, 16) : (16, 0, 48, 48)
                    return el().size(96, 64).child(
                        capsule.child(
                            el().absolute(x: x, y: y).size(w, h).scrollY().scrollEdgeFade(0).clip().child(
                                el().size(120, 120).bg(.white)
                            )
                        )
                    )
                }
                rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                rt.srgbBlend = true
                let rf = rt.renderFrame(at: 0.0)
                let frame = try renderer.renderOffscreen(rf)
                #if canImport(Metal)
                #expect(renderer.metal.layerStats().targets == 0)
                #endif
                frames.append(frame.rgba)
            }
            #expect(frames[0] == frames[1], "central strip misses every rounded corner")
        }
    }

    // 11c. #139c (`rounded_clip_tests.rs:401`)
    @Test("rounded_clip_single_line_input_keeps_the_original_mask")
    func roundedClipSingleLineInputKeepsTheOriginalMask() throws {
        struct State {
            var rounded: Bool
            var edit = TextEdit("MMMMMMMMMMMM")
        }
        let renderer = try OffscreenGPURenderer()
        for scale: Float in [1.0, 2.0] {
            let w = Int((96.0 * scale).rounded())
            let h = Int((56.0 * scale).rounded())
            var frames: [[UInt8]] = []
            for rounded in [false, true] {
                let rt = Runtime<State>(state: State(rounded: rounded), viewport: Vec2(96, 56), pixelScale: scale) { s, _ in
                    var capsule: El<State> = el().size(80, 40).absolute(x: 8, y: 8)
                    if s.rounded { capsule = capsule.clipRounded(20) }
                    return el().size(96, 56).child(
                        capsule.child(
                            textInput(key: "edit", \State.edit).font(TextStyle(size: 28, weight: 700))
                                .singleLine().size(64, 40).absolute(x: 8, y: 0)
                        )
                    )
                }
                rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                rt.srgbBlend = true
                let rf = rt.renderFrame(at: 0.0)
                frames.append(try renderer.renderOffscreen(rf).rgba)
            }
            #expect(stride(from: 3, to: frames[0].count, by: 4).contains { frames[0][$0] > 0 })
            for y in 0..<h {
                for x in 0..<w {
                    let a = mask(Float(x) + 0.5, Float(y) + 0.5, [8 * scale, 8 * scale, 88 * scale, 48 * scale], 20.0 * scale)
                    let at = (y * w + x) * 4 + 3
                    let want = UInt8((Float(frames[0][at]) * a).rounded())
                    #expect(abs(Int(frames[1][at]) - Int(want)) <= 1, "scale=\(scale) (\(x),\(y))")
                }
            }
        }
    }

    #endif

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // 11d. #139d (`rounded_clip_tests.rs:434`)
    @Test("per_corner_continuous_card_clips_image_child_and_nested_layers")
    func perCornerContinuousCardClipsImageChildAndNestedLayers() throws {
        let renderer = try OffscreenGPURenderer()
        let cardImg = Pixels()
        var cardRgba: [UInt8] = []
        cardRgba.reserveCapacity(80 * 56 * 4)
        for y in 0..<56 {
            for x in 0..<80 {
                cardRgba.append(UInt8(36 + x * 2))
                cardRgba.append(UInt8(64 + y * 3))
                cardRgba.append(UInt8(210 - x * 2))
                cardRgba.append(255)
            }
        }
        cardImg.set(width: 80, height: 56, rgba: cardRgba)

        let childImg = Pixels()
        var childRgba: [UInt8] = []
        childRgba.reserveCapacity(96 * 72 * 4)
        for y in 0..<72 {
            for x in 0..<96 {
                if (8..<88).contains(x) && (8..<64).contains(y) {
                    let cx = x - 8
                    let cy = y - 8
                    childRgba.append(UInt8(36 + cx * 2))
                    childRgba.append(UInt8(64 + cy * 3))
                    childRgba.append(UInt8(210 - cx * 2))
                    childRgba.append(255)
                } else {
                    childRgba.append(contentsOf: [255, 60, 120, 255])
                }
            }
        }
        childImg.set(width: 96, height: 72, rgba: childRgba)

        for corners in [Corners(14, 14, 0, 0), Corners(18, 6, 14, 4)] {
            typealias State = (card: Pixels, child: Pixels, corners: Corners, mode: UInt8)
            var outs: [[UInt8]] = []
            for mode: UInt8 in 0..<3 {
                let rt = Runtime<State>(state: (cardImg, childImg, corners, mode), viewport: Vec2(128, 96), pixelScale: 1.0) { s, _ in
                    let inner: El<State>
                    switch s.mode {
                    case 0:
                        inner = el().size(80, 56).absolute(x: 24, y: 20).clipSoft(0).child(
                            el().size(80, 56).corners(s.corners.topLeft, s.corners.topRight, s.corners.bottomRight, s.corners.bottomLeft)
                                .continuousCorners().pixels(s.card)
                        )
                    case 1:
                        inner = el().size(80, 56).absolute(x: 24, y: 20)
                            .corners(s.corners.topLeft, s.corners.topRight, s.corners.bottomRight, s.corners.bottomLeft)
                            .continuousCorners()
                            .clipRounded(s.corners.topLeft)
                            .child(el().size(96, 72).absolute(x: -8, y: -8).pixels(s.child))
                    default:
                        inner = el().size(80, 56).absolute(x: 24, y: 20)
                            .continuousCorners()
                            .clipCorners(s.corners)
                            .opacity(0.9999)
                            .child(el().size(96, 72).absolute(x: -8, y: -8).pixels(s.child))
                    }
                    return el().size(128, 96).child(inner)
                }
                rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                rt.srgbBlend = true
                let rf = rt.renderFrame(at: 0.0)
                #if canImport(Metal)
                let rgba = try drawRaw(renderer: renderer.metal, frame: rf)
                #else
                // Offscreen capture returns straight RGBA. Compare the stored
                // premultiplied colors here, including the antialiased borders.
                var rgba = try renderer.renderOffscreen(rf).rgba
                for i in stride(from: 0, to: rgba.count, by: 4) {
                    let alpha = Int(rgba[i + 3])
                    for channel in i..<(i + 3) { rgba[channel] = UInt8((Int(rgba[channel]) * alpha + 127) / 255) }
                }
                #endif
                if mode == 1 {
                    #expect(renderer.layerStats().extraPasses == 0, "mixed continuous clip stays on the direct path")
                } else if mode == 2 {
                    #expect(renderer.layerStats().extraPasses == 1, "isolated layer path exercised")
                }
                outs.append(rgba)
            }
            if corners.bottomRight == 0.0 {
                let tlAlpha = outs[1][(20 * 128 + 24) * 4 + 3]
                let brIndex = ((20 + 55) * 128 + (24 + 79)) * 4 + 3
                let brAlpha = outs[1][brIndex]
                #expect(tlAlpha == 0, "top-left continuous corner is clipped")
                #expect(brAlpha == 255, "bottom-right zero-radius corner stays sharp")
            }
            for mode in [1, 2] {
                for idx in 0..<outs[mode].count {
                    #expect(abs(Int(outs[mode][idx]) - Int(outs[0][idx])) <= 1, "corners=\(corners) mode=\(mode) byte \(idx): got \(outs[mode][idx]) vs want \(outs[0][idx])")
                }
            }
        }

        // Nested mixed-corner clips fall back to an outer layer and intersect both masks.
        let rtNested = Runtime<Pixels>(state: cardImg, viewport: Vec2(128, 96), pixelScale: 1.0) { img, _ in
            el().size(128, 96).child(
                el().size(80, 56).absolute(x: 24, y: 20)
                    .corners(16, 16, 0, 0).continuousCorners().clipRounded(16)
                    .child(
                        el().size(80, 56)
                            .corners(0, 0, 16, 16).continuousCorners().clipRounded(16)
                            .child(el().size(80, 56).pixels(img))
                    )
            )
        }
        rtNested.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rtNested.srgbBlend = true
        let rfNested = rtNested.renderFrame(at: 0.0)
        let nestedFrame = try renderer.renderOffscreen(rfNested)
        #expect(renderer.layerStats().extraPasses == 1, "nested distinct per-corner clips open one outer layer")
        for (x, y) in [(24, 20), (103, 20), (103, 75), (24, 75)] {
            #expect(nestedFrame.rgba[(y * 128 + x) * 4 + 3] == 0, "all four corners are clipped at (\(x),\(y))")
        }
        #expect(nestedFrame.rgba[(48 * 128 + 64) * 4 + 3] == 255, "interior remains opaque")
    }
    #endif
}
