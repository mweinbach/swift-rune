import Foundation
import Testing
@testable import Rune
import RuneMotion
#if canImport(simd)
import simd
#endif
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("Render Closeout Gap Parity Tests")
struct RenderCloseoutGapTests {
    private static func premul(_ c: Color, opacity: Float = 1.0, srgb: Bool = false) -> SIMD4<Float> {
        let v = c.simd4(srgb: srgb)
        let a = (v.w * opacity).clamped(to: 0...1)
        return SIMD4<Float>(v.x * a, v.y * a, v.z * a, a)
    }

    private static func srgbEncode(_ c: Float) -> Float {
        let x = min(max(c, 0), 1)
        if x <= 0.0031308 { return x * 12.92 }
        return 1.055 * powf(x, 1.0 / 2.4) - 0.055
    }

    private static func srgbDecode(_ u: Float) -> Float {
        let x = min(max(u, 0), 1)
        if x <= 0.04045 { return x / 12.92 }
        return powf((x + 0.055) / 1.055, 2.4)
    }

    private static func erfApprox(_ x: Float) -> Float {
        let s: Float = x >= 0 ? 1.0 : -1.0
        let a = abs(x)
        let r = 1.0 + (0.278393 + (0.230389 + 0.078108 * a * a) * a) * a
        let r2 = r * r
        return s - s / (r2 * r2)
    }

    private static func near4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tol: Float = 1e-4) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.z - b.z) < tol && abs(a.w - b.w) < tol
    }

    private static func approxRGBA(_ a: [UInt8], _ b: [UInt8], tol: Int = 2) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        return abs(Int(a[0]) - Int(b[0])) <= tol
            && abs(Int(a[1]) - Int(b[1])) <= tol
            && abs(Int(a[2]) - Int(b[2])) <= tol
    }

    // MARK: - `border_gradient.rs:75, 88`

    @Test("border_gradient_springs_from_a_solid_border (border_gradient.rs:75)")
    func borderGradientSpringsFromSolidBorder() {
        enum Mode { case rimBorder, gradient }
        let top = Color(r: 1, g: 0, b: 0, a: 1)
        let bottom = Color(r: 0, g: 0, b: 1, a: 1)
        let rim = Color(r: 1, g: 1, b: 1, a: 0.15)
        let dark = Color(r: 0.1, g: 0.1, b: 0.12, a: 1)

        let rt = Runtime<Mode>(
            state: .rimBorder,
            viewport: Vec2(68, 22),
            pixelScale: 2.0,
            view: { (mode: Mode, _) -> El<Mode> in
                let cap: El<Mode> = el().absolute(x: 4, y: 4).size(60, 14).rounded(7)
                let styled: El<Mode> = switch mode {
                case .rimBorder: cap.bg(dark).border(0.5, rim)
                case .gradient: cap.borderGradient(width: 0.5, top: top, bottom: bottom)
                }
                return el().size(68, 22).child(styled)
            }
        )
        rt.setSrgbBlend(false)
        _ = rt.renderFrame(at: 0)
        rt.update { s, _ in s = .gradient }
        let midFrame = rt.renderFrame(at: 0.03)
        let ring = midFrame.instances.first(where: { $0.params.x > 0 })
        #expect(ring != nil)
        if let ring {
            #expect(ring.params.y == KIND_GRADIENT)
            let rimP = Self.premul(rim)
            let botP = Self.premul(bottom)
            #expect(ring.uv.w > rimP.w && ring.uv.w < botP.w && ring.uv.z < botP.z)
        }
        let settled = rt.renderFrame(at: 5.0)
        let settledRing = settled.instances.first(where: { $0.params.x > 0 })
        #expect(settledRing != nil)
        if let settledRing {
            #expect(Self.near4(settledRing.uv, Self.premul(bottom)))
        }
    }

    @Test("solid_border_springs_from_a_gradient_without_moving_a_settled_bottom (border_gradient.rs:88)")
    func solidBorderSpringsFromGradientWithoutMovingSettledBottom() {
        enum Mode { case gradient, solidBottom }
        let top = Color(r: 1, g: 0, b: 0, a: 1)
        let bottom = Color(r: 0, g: 0, b: 1, a: 1)

        let rt = Runtime<Mode>(
            state: .gradient,
            viewport: Vec2(68, 22),
            pixelScale: 2.0,
            view: { (mode: Mode, _) -> El<Mode> in
                let cap: El<Mode> = el().absolute(x: 4, y: 4).size(60, 14).rounded(7)
                let styled: El<Mode> = switch mode {
                case .gradient: cap.borderGradient(width: 0.5, top: top, bottom: bottom)
                case .solidBottom: cap.border(0.5, bottom)
                }
                return el().size(68, 22).child(styled)
            }
        )
        rt.setSrgbBlend(false)
        _ = rt.renderFrame(at: 0)
        rt.update { s, _ in s = .solidBottom }
        let bottomP = Self.premul(bottom)
        var kinds: [Float] = []
        for step in 1...120 {
            let rf = rt.renderFrame(at: Double(step) / 60.0)
            guard let ring = rf.instances.first(where: { $0.params.x > 0 }) else {
                Issue.record("missing border ring at step \(step)")
                return
            }
            let edge = ring.params.y == KIND_GRADIENT ? ring.uv : ring.border
            #expect(Self.near4(edge, bottomP, tol: 1e-4), "step \(step): bottom moved to \(edge)")
            kinds.append(ring.params.y)
        }
        #expect(kinds.first == KIND_GRADIENT)
        let settled = rt.renderFrame(at: 5.0)
        if let finalRing = settled.instances.first(where: { $0.params.x > 0 }) {
            #expect(finalRing.params.y == KIND_RECT)
            #expect(Self.near4(finalRing.border, bottomP, tol: 1e-4))
            #expect(finalRing.uv == .zero)
        } else {
            Issue.record("missing final settled ring")
        }
    }

    #if canImport(Metal)

    // MARK: - `radial_srgb.rs:61, 95, 217, 318`

    @Test("radial_gradient_centre_edge_and_monotonic_falloff (radial_srgb.rs:61)")
    func radialGradientCentreEdgeAndMonotonicFalloff() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(120, 120),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(120, 120).radialGradient(
                    center: Vec2(0.5, 0.5),
                    radius: .pixels(50),
                    stops: [
                        GradientStop(.white, at: 0),
                        GradientStop(.black, at: 1),
                    ]
                )
            }
        )
        rt.setSrgbBlend(false)
        let rf = rt.renderFrame(at: 0)
        #expect(rf.instances.count == 1)
        if let inst = rf.instances.first {
            #expect(inst.params.y == KIND_RADIAL)
            #expect(inst.uv == SIMD4<Float>(60, 60, 50, 50))
        }
        let img = try renderer.renderOffscreen(rf)
        let center = img.pixel(x: 60, y: 60)
        let edge = img.pixel(x: 115, y: 60)
        #expect(center.x >= 253 && center.y >= 253 && center.z >= 253 && center.w == 255)
        #expect(edge == SIMD4<UInt8>(0, 0, 0, 255))

        var prev = center.x
        for x in 60..<115 {
            let p = img.pixel(x: x, y: 60).x
            #expect(p <= prev, "non-monotonic at x=\(x): \(p) > \(prev)")
            prev = p
        }
        let mid = img.pixel(x: 85, y: 60).x
        #expect(mid > 80 && mid < 220)
    }

    @Test("radial_gradient_multi_stop_elliptical_quad_shrinking_and_validation (radial_srgb.rs:95)")
    func radialGradientMultiStopEllipticalQuadShrinkingAndValidation() throws {
        let renderer = try MetalRenderer()
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(140, 100),
            pixelScale: 1.0,
            view: { swap, _ in
                let mid = swap ? Color(r: 1, g: 1, b: 0, a: 1) : Color(r: 0, g: 1, b: 0, a: 1)
                return el().size(140, 100).child(
                    el()
                        .absolute(x: 10, y: 10)
                        .size(120, 80)
                        .rounded(20)
                        .bg(Color(r: 0.1, g: 0.1, b: 0.1, a: 1))
                        .radialGradient(
                            center: Vec2(0.5, 0.5),
                            radius: .xy(50, 25),
                            stops: [
                                GradientStop(Color(r: 1, g: 0, b: 0, a: 1), at: 0),
                                GradientStop(mid, at: 0.5),
                                GradientStop(Color(r: 0, g: 0, b: 1, a: 1), at: 1),
                            ]
                        )
                        .border(2, .white)
                        .opacity(0.9)
                )
            }
        )
        rt.setSrgbBlend(false)
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        let rf = rt.renderFrame(at: 0)
        let radials = rf.instances.filter { $0.params.y == KIND_RADIAL }
        #expect(radials.count == 2)
        if radials.count == 2 {
            #expect(radials[0].rect.z <= 54.0 && radials[0].rect.w <= 28.0)
            #expect(radials[1].rect == SIMD4<Float>(10, 10, 120, 80))
        }

        let img = try renderer.renderOffscreen(rf)
        // Corner outside 20pt rounded rect is transparent
        #expect(img.pixel(x: 11, y: 11).w == 0)
        // Center (70, 50) red
        let cCenter = img.pixel(x: 70, y: 50)
        #expect(cCenter.x > 200 && cCenter.y < 70 && cCenter.z < 40)
        // Midpoints (95, 50) and (70, 62) green
        let cMidX = img.pixel(x: 95, y: 50)
        let cMidY = img.pixel(x: 70, y: 62)
        #expect(cMidX.y > 200 && cMidX.x < 90 && cMidX.z < 90)
        #expect(cMidY.y > 200 && cMidY.x < 90 && cMidY.z < 90)
        // Outer (120, 50) blue
        let cOuter = img.pixel(x: 120, y: 50)
        #expect(cOuter.z > 200 && cOuter.x < 40 && cOuter.y < 40)
        // Border at (70, 11) white
        let cBorder = img.pixel(x: 70, y: 11)
        #expect(cBorder.x > 210 && cBorder.y > 210 && cBorder.z > 210)

        // Stop colours animate via Oklab springs when state updates
        rt.update { s, _ in s = true }
        let animRf = rt.renderFrame(at: 0.04)
        let midAnim = try renderer.renderOffscreen(animRf)
        let pAnim = midAnim.pixel(x: 95, y: 50)
        #expect(pAnim.x > cMidX.x + 20 && pAnim.x < 245)

        // Half-valid radii dropped & stops > 16 capped to 16 stops (15 segments)
        struct S {}
        let manyStops = (0..<18).map { i in GradientStop(.white, at: Float(i) / 17.0) }
        let rtEdge = Runtime<S>(
            state: S(),
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(100, 100)
                    .child(el().size(50, 50).radialGradient(center: Vec2(0.5, 0.5), radius: .xy(10, 0), stops: [
                        GradientStop(.white, at: 0),
                        GradientStop(.black, at: 1),
                    ]))
                    .child(el().size(50, 50).radialGradient(center: Vec2(0.5, 0.5), radius: .pixels(25), stops: manyStops))
            }
        )
        let edgeRf = rtEdge.renderFrame(at: 0)
        let edgeRadials = edgeRf.instances.filter { $0.params.y == KIND_RADIAL }
        #expect(edgeRadials.count == 15)
        #expect(edgeRadials.allSatisfy { $0.uv.z > 0 && $0.uv.w > 0 })

        // linearGradient(.pi) matches vertical gradient(a, b) and diag linearGradient
        let rtV = Runtime<Bool>(
            state: false,
            viewport: Vec2(80, 60),
            pixelScale: 1.0,
            view: { angled, _ in
                let a = Color(r: 1, g: 0, b: 0, a: 1)
                let b = Color(r: 0, g: 0, b: 1, a: 1)
                let card: El<Bool> = el().size(80, 60).rounded(8)
                return angled
                    ? card.linearGradient(angle: .pi, stops: [GradientStop(a, at: 0), GradientStop(b, at: 1)])
                    : card.gradient(a, b)
            }
        )
        let rtL = Runtime<Bool>(
            state: true,
            viewport: Vec2(80, 60),
            pixelScale: 1.0,
            view: { angled, _ in
                let a = Color(r: 1, g: 0, b: 0, a: 1)
                let b = Color(r: 0, g: 0, b: 1, a: 1)
                let card: El<Bool> = el().size(80, 60).rounded(8)
                return angled
                    ? card.linearGradient(angle: .pi, stops: [GradientStop(a, at: 0), GradientStop(b, at: 1)])
                    : card.gradient(a, b)
            }
        )
        let pxV = try renderer.renderOffscreen(rtV.renderFrame(at: 0)).rgba
        let pxL = try renderer.renderOffscreen(rtL.renderFrame(at: 0)).rgba
        #expect(zip(pxV, pxL).allSatisfy { abs(Int($0) - Int($1)) <= 1 })

        let rtDiag = Runtime<S>(
            state: S(),
            viewport: Vec2(80, 80),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(80, 80).child(
                    el()
                        .absolute(x: 10, y: 10)
                        .size(60, 60)
                        .linearGradient(angle: Float.pi / 4.0, stops: [
                            GradientStop(.white, at: 0),
                            GradientStop(.black, at: 1),
                        ])
                        .blur(2)
                )
            }
        )
        let diagImg = try renderer.renderOffscreen(rtDiag.renderFrame(at: 0))
        #expect(diagImg.pixel(x: 20, y: 60).x > diagImg.pixel(x: 60, y: 20).x + 100)
    }

    @Test("srgb_blend_matches_css_and_core_animation_glow_reference (radial_srgb.rs:217)")
    func srgbBlendMatchesCssAndCoreAnimationGlowReference() throws {
        let renderer = try MetalRenderer()
        let bg = hex("#100e11")!
        let glow = hex("#40bf80")!.alpha(0.16)
        let bgSrgb = [Self.srgbEncode(bg.r), Self.srgbEncode(bg.g), Self.srgbEncode(bg.b)]
        let glowSrgb = [Self.srgbEncode(glow.r), Self.srgbEncode(glow.g), Self.srgbEncode(glow.b)]

        struct S {}
        func makeRt(srgbBlend: Bool) -> Runtime<S> {
            let rt = Runtime<S>(
                state: S(),
                viewport: Vec2(240, 240),
                pixelScale: 1.0,
                view: { _, _ in
                    el().size(240, 240).bg(bg).child(
                        el()
                            .absolute(x: 60, y: 60)
                            .size(120, 120)
                            .rounded(24)
                            .shadow(Shadow(x: 0, y: 0, blur: 30, spread: 0, color: glow))
                    )
                }
            )
            rt.setSrgbBlend(srgbBlend)
            return rt
        }

        let pxLinear = try renderer.renderOffscreen(makeRt(srgbBlend: false).renderFrame(at: 0))
        let pxSrgb = try renderer.renderOffscreen(makeRt(srgbBlend: true).renderFrame(at: 0))

        let expectedCenter: [UInt8] = (0..<3).map { c in
            UInt8(((glowSrgb[c] * 0.16 + bgSrgb[c] * 0.84) * 255.0).rounded())
        }
        #expect(expectedCenter == [24, 42, 35])
        let linC = pxLinear.pixel(x: 120, y: 120)
        let srgbC = pxSrgb.pixel(x: 120, y: 120)
        #expect(linC == SIMD4<UInt8>(29, 83, 56, 255))
        #expect([srgbC.x, srgbC.y, srgbC.z] == expectedCenter)

        let sigma: Float = 15.0
        let scale = sqrtf(0.5) / sigma
        var maxErrLin = 0
        var maxErrSrgb = 0
        for x in 15...120 {
            let px = Float(x) + 0.5 - 120.0
            let w = 0.5 * (Self.erfApprox((px + 60.0) * scale) - Self.erfApprox((px - 60.0) * scale))
            let a = 0.16 * w
            let pLin = pxLinear.pixel(x: x, y: 120)
            let pSrgb = pxSrgb.pixel(x: x, y: 120)
            let valsLin = [pLin.x, pLin.y, pLin.z]
            let valsSrgb = [pSrgb.x, pSrgb.y, pSrgb.z]
            for c in 0..<3 {
                let refC = Int(((glowSrgb[c] * a + bgSrgb[c] * (1.0 - a)) * 255.0).rounded())
                maxErrLin = max(maxErrLin, abs(Int(valsLin[c]) - refC))
                maxErrSrgb = max(maxErrSrgb, abs(Int(valsSrgb[c]) - refC))
            }
        }
        #expect(maxErrLin >= 40)
        #expect(maxErrSrgb <= 1)

        // Layer blur (.bg(glow).blur(15)) in srgbBlend matches centre
        let rtBlur = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 240),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(240, 240).bg(bg).child(
                    el()
                        .absolute(x: 60, y: 60)
                        .size(120, 120)
                        .rounded(24)
                        .bg(glow)
                        .blur(15)
                )
            }
        )
        rtBlur.setSrgbBlend(true)
        let pxBlur = try renderer.renderOffscreen(rtBlur.renderFrame(at: 0))
        let blurC = pxBlur.pixel(x: 120, y: 120)
        #expect(Self.approxRGBA([blurC.x, blurC.y, blurC.z], expectedCenter, tol: 1))
    }

    private final class SrgbCheckCompositor: Compositor {
        typealias State = Int
        var seen: (srgbBlend: Bool, format: MTLPixelFormat)?

        func render(frame: CompositorFrame<Int>) {
            seen = (frame.srgbBlend, frame.pixelFormat)
            frame.drawUI()
        }
    }

    @Test("srgb_blend_images_surfaces_keycaps_and_compositor (radial_srgb.rs:318)")
    func srgbBlendImagesSurfacesKeycapsAndCompositor() throws {
        let renderer = try MetalRenderer()
        let cache = ImageCache()
        let premulBytes = Array(repeating: [UInt8](arrayLiteral: 255, 255, 255, 128), count: 16 * 16).flatMap { $0 }
        let premulImg = cache.rgba(width: 16, height: 16, data: premulBytes)
        premulImg.wait()

        let straightPx = Pixels()
        straightPx.set(width: 16, height: 16, rgba: premulBytes)

        let bgraSurface = NativeSurface()
        let bgraBytes = Array(repeating: [UInt8](arrayLiteral: 128, 128, 128, 255), count: 16 * 16).flatMap { $0 }
        try bgraSurface.pushBytes(try ByteFrame(width: 16, height: 16, format: .bgra, color: .srgb, planes: [Data(bgraBytes)]), frameId: 1)

        let nv12Surface = NativeSurface()
        try nv12Surface.pushBytes(
            try ByteFrame(
                width: 16,
                height: 16,
                format: .nv12Full,
                color: .srgb,
                planes: [Data(repeating: 128, count: 16 * 16), Data(repeating: 128, count: 8 * 8 * 2)]
            ),
            frameId: 1
        )

        struct MediaState {
            let premulPx: Pixels
            let straightPx: Pixels
            let bgraSurface: NativeSurface
            let nv12Surface: NativeSurface
        }
        let media = MediaState(premulPx: premulImg.pixels, straightPx: straightPx, bgraSurface: bgraSurface, nv12Surface: nv12Surface)
        let rt = Runtime<MediaState>(
            state: media,
            viewport: Vec2(120, 40),
            pixelScale: 1.0,
            view: { s, _ in
                el().size(120, 40)
                    .bg(hex("#808080")!)
                    .child(el().absolute(x: 4, y: 4).size(16, 16).pixels(s.premulPx))
                    .child(el().absolute(x: 24, y: 4).size(16, 16).pixels(s.straightPx))
                    .child(el().absolute(x: 44, y: 4).size(16, 16).nativeSurface(s.bgraSurface, .fill))
                    .child(el().absolute(x: 64, y: 4).size(16, 16).nativeSurface(s.nv12Surface, .fill))
                    .child(el().absolute(x: 84, y: 4).size(16, 16).nativeSurface(s.bgraSurface, .fill).blur(0.5))
            }
        )
        rt.setSrgbBlend(true)
        let img = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        let pPremul = img.pixel(x: 12, y: 12)
        let pStraight = img.pixel(x: 32, y: 12)
        let pBgra = img.pixel(x: 52, y: 12)
        let pNv12 = img.pixel(x: 72, y: 12)
        let pLayerSurf = img.pixel(x: 92, y: 12)
        #expect(Self.approxRGBA([pPremul.x, pPremul.y, pPremul.z], [191, 191, 191], tol: 2))
        #expect(Self.approxRGBA([pStraight.x, pStraight.y, pStraight.z], [191, 191, 191], tol: 2))
        #expect(Self.approxRGBA([pBgra.x, pBgra.y, pBgra.z], [128, 128, 128], tol: 2))
        #expect(Self.approxRGBA([pNv12.x, pNv12.y, pNv12.z], [128, 128, 128], tol: 2))
        #expect(Self.approxRGBA([pLayerSurf.x, pLayerSurf.y, pLayerSurf.z], [128, 128, 128], tol: 2))

        // Compositor receives `srgbBlend = true` and non-sRGB target format (`.bgra8Unorm`)
        let comp = SrgbCheckCompositor()
        let app = App<Int>(title: "comp-srgb", size: Vec2(64, 64), state: 0) { _, _ in
            el().size(64, 64).bg(hex("#808080")!)
        }
        .srgbBlend(true)
        .compositor(comp)
        _ = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--scale", "1"]))
        #expect(comp.seen?.srgbBlend == true)
        #expect(comp.seen?.format == .bgra8Unorm)
    }

    // MARK: - `effect_data.rs:90, 126, 186`

    private struct SeenSlot {
        let mark: UInt32
        let data: SIMD4<Float>
        let rect: SIMD4<Float>
        let scale: Float
        let inLayer: Bool
        let opacity: Float
        let turn: Float
    }

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func withLock<R>(_ body: (inout T) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private func recordSlots<S>(_ renderer: MetalRenderer, _ rt: Runtime<S>, at now: Double) throws -> [SeenSlot] {
        var seen: [SeenSlot] = []
        let rf = rt.renderFrame(at: now)
        _ = try renderer.renderOffscreen(rf, hook: { _, s in
            seen.append(SeenSlot(
                mark: s.mark,
                data: s.data,
                rect: s.instance.rect,
                scale: s.scale,
                inLayer: s.inLayer,
                opacity: s.opacity,
                turn: s.turn
            ))
        })
        return seen
    }

    @Test("sibling_slots_each_hand_the_hook_their_own_mark_and_payload (effect_data.rs:90)")
    func siblingSlotsEachHandHookOwnMarkAndPayload() throws {
        let renderer = try MetalRenderer()
        struct Pair { var version: UInt32; var other: UInt32 }
        let deadBeef = Float(bitPattern: 0xDEAD_BEEF)
        let customNan = Float(bitPattern: 0x7FC0_1234)
        func pairSlots(_ version: UInt32) -> El<Pair> {
            el().size(96, 40)
                .child(el().absolute(x: 8, y: 8).size(16, 16).effect(7).effectData(SIMD4<Float>(1, 2, 3, Float(version))))
                .child(el().absolute(x: 40, y: 8).size(16, 16).effect(70_000).effectData(SIMD4<Float>(deadBeef, -0.5, customNan, 0)))
        }

        let rt = Runtime<Pair>(
            state: Pair(version: 1, other: 1),
            viewport: Vec2(96, 96),
            pixelScale: 1.0,
            view: { s, _ in
                let v = s.version
                return el().size(96, 96)
                    .child(el().key("plain").child(pairSlots(0)))
                    .child(el().key("cached").absolute(x: 0, y: 48).cache().child(memo("slots", deps: v) { pairSlots(v) }))
                    .child(el().key("tick").size(Float(s.other), 1))
            }
        )

        func verify(_ seen: [SeenSlot], version: Float) {
            #expect(seen.map(\.mark) == [7, 70_000, 7, 70_000])
            for (k, s) in seen.enumerated() {
                let want: SIMD4<Float> = s.mark == 7
                    ? SIMD4<Float>(1, 2, 3, k < 2 ? 0 : version)
                    : SIMD4<Float>(deadBeef, -0.5, customNan, 0)
                #expect(s.data.x.bitPattern == want.x.bitPattern)
                #expect(s.data.y.bitPattern == want.y.bitPattern)
                #expect(s.data.z.bitPattern == want.z.bitPattern)
                #expect(s.data.w.bitPattern == want.w.bitPattern)
                #expect(!s.inLayer && s.opacity == 1.0)
            }
        }

        verify(try recordSlots(renderer, rt, at: 0), version: 1)
        rt.update { s, _ in s.other = 2 }
        verify(try recordSlots(renderer, rt, at: 1.0 / 60.0), version: 1)
        rt.update { s, _ in s.version = 5 }
        verify(try recordSlots(renderer, rt, at: 2.0 / 60.0), version: 5)
    }

    @Test("an_exiting_slot_keeps_its_mark_and_payload_while_its_replacement_enters (effect_data.rs:126)")
    func exitingSlotKeepsMarkAndPayloadWhileReplacementEnters() throws {
        let renderer = try MetalRenderer()
        struct Pages { var page: UInt32; var phase: Float }
        let rt = Runtime<Pages>(
            state: Pages(page: 1, phase: 0.25),
            viewport: Vec2(96, 96),
            pixelScale: 1.0,
            view: { s, _ in
                let x: Float = (s.page % 2 == 0) ? 48 : 8
                return el().size(96, 96).child(
                    el()
                        .key("hud\(s.page)")
                        .absolute(x: x, y: 8)
                        .size(32, 32)
                        .effect(UInt64(100 + s.page))
                        .effectData(SIMD4<Float>(Float(s.page), s.phase, 0, 0))
                        .transition(.opacity)
                )
            }
        )
        let first = try recordSlots(renderer, rt, at: 0)
        #expect(first.count == 1)
        if let s0 = first.first {
            #expect(s0.mark == 101 && s0.data == SIMD4<Float>(1, 0.25, 0, 0) && !s0.inLayer)
        }

        rt.update { s, _ in
            s.page = 2
            s.phase = 0.75
        }
        var both = 0
        var now = 0.0
        for frame in 0..<60 {
            now += 1.0 / 60.0
            let seen = try recordSlots(renderer, rt, at: now)
            let newSlot = seen.first(where: { $0.mark == 102 })
            #expect(newSlot != nil)
            if let newSlot {
                #expect(newSlot.data == SIMD4<Float>(2, 0.75, 0, 0))
                #expect(Self.near4(newSlot.rect, SIMD4<Float>(48, 8, 32, 32), tol: 1.0))
                if frame == 0 {
                    #expect(newSlot.inLayer && newSlot.opacity < 1.0)
                }
            }
            guard let oldSlot = seen.first(where: { $0.mark == 101 }) else { continue }
            both += 1
            #expect(oldSlot.data == SIMD4<Float>(1, 0.25, 0, 0))
            let elOld = rt.element(byKey: "hud1")
            #expect(elOld?.exiting == true)
            #expect(oldSlot.inLayer && oldSlot.opacity < 1.0)
            if let elOld {
                #expect(abs(oldSlot.opacity - elOld.opacity) < 1e-3)
            }
            #expect(Self.near4(oldSlot.rect, SIMD4<Float>(8, 8, 32, 32), tol: 1.0))
        }
        #expect(both >= 3)
        now += 1.0
        let settled = try recordSlots(renderer, rt, at: now)
        #expect(settled.count == 1)
        if let s = settled.first {
            #expect(!s.inLayer && s.opacity == 1.0)
        }
    }

    @Test("slots_follow_scale_offset_and_transitions_and_turn_in_a_layer (effect_data.rs:186)")
    func slotsFollowScaleOffsetTransitionsAndTurnInLayer() throws {
        let k: Float = 2.0
        let renderer = try MetalRenderer()
        struct Moves { var extra: Bool }
        let rt = Runtime<Moves>(
            state: Moves(extra: false),
            viewport: Vec2(160, 160),
            pixelScale: k,
            view: { (s: Moves, _) -> El<Moves> in
                var root: El<Moves> = el().size(160, 160)
                    .child(el().key("scaled").absolute(x: 8, y: 8).size(16, 16).effect(1).scale(1.5))
                    .child(el().key("offset").absolute(x: 40, y: 8).size(16, 16).effect(2).offset(5, 3))
                    .child(el().key("rotated").absolute(x: 8, y: 40).size(16, 16).effect(3).rotate(0.5))
                    .child(
                        el().key("parent").absolute(x: 40, y: 40).size(32, 32).scale(2.0)
                            .child(el().key("child").absolute(x: 8, y: 8).size(8, 8).effect(4))
                    )
                if s.extra {
                    root = root.child(
                        el().key("moving").absolute(x: 96, y: 96).size(32, 32).effect(5)
                            .transition(Transition.scale(0.5).combined(with: Transition.offset(x: 0, y: 24)))
                    )
                }
                return root
            }
        )

        func checkPresented(_ slot: SeenSlot, _ elem: ElementInfo) {
            let scaledRect = SIMD4<Float>(elem.rect[0] * k, elem.rect[1] * k, elem.rect[2] * k, elem.rect[3] * k)
            #expect(Self.near4(slot.rect, scaledRect, tol: 1.01))
            #expect(abs(slot.scale - elem.scale * k) < 1e-3)
        }

        let seen0 = try recordSlots(renderer, rt, at: 0)
        if let scaled = seen0.first(where: { $0.mark == 1 }), let e = rt.element(byKey: "scaled") {
            #expect(Self.near4(scaled.rect, SIMD4<Float>(4 * k, 4 * k, 24 * k, 24 * k), tol: 0.05))
            #expect(abs(scaled.scale - 1.5 * k) < 1e-4)
            checkPresented(scaled, e)
        } else { Issue.record("missing scaled slot") }
        if let offset = seen0.first(where: { $0.mark == 2 }) {
            #expect(Self.near4(offset.rect, SIMD4<Float>(45 * k, 11 * k, 16 * k, 16 * k), tol: 0.05))
            #expect(abs(offset.scale - k) < 1e-4)
        } else { Issue.record("missing offset slot") }
        if let child = seen0.first(where: { $0.mark == 4 }), let e = rt.element(byKey: "child") {
            #expect(abs(child.scale - 2.0 * k) < 1e-4)
            checkPresented(child, e)
        } else { Issue.record("missing child slot") }
        if let rot = seen0.first(where: { $0.mark == 3 }) {
            #expect(Self.near4(rot.rect, SIMD4<Float>(8 * k, 40 * k, 16 * k, 16 * k), tol: 0.05))
            #expect(abs(rot.scale - k) < 1e-4)
            #expect(rot.inLayer && abs(rot.turn - 0.5) < 1e-4)
        } else { Issue.record("missing rotated slot") }

        rt.update { s, _ in s.extra = true }
        var entering = 0
        var now = 0.0
        for _ in 0..<60 {
            now += 1.0 / 60.0
            let seen = try recordSlots(renderer, rt, at: now)
            guard let slot = seen.first(where: { $0.mark == 5 }), let e = rt.element(byKey: "moving") else {
                Issue.record("missing entering moving slot")
                return
            }
            checkPresented(slot, e)
            if e.scale < 0.999 {
                entering += 1
                #expect(slot.rect.y > 96.0 * k)
                #expect(slot.inLayer && abs(slot.opacity - e.opacity) < 1e-3)
            }
        }
        #expect(entering >= 3)

        rt.update { s, _ in s.extra = false }
        var exiting = 0
        for _ in 0..<60 {
            now += 1.0 / 60.0
            let seen = try recordSlots(renderer, rt, at: now)
            guard let slot = seen.first(where: { $0.mark == 5 }), let e = rt.element(byKey: "moving") else { continue }
            #expect(e.exiting)
            checkPresented(slot, e)
            if e.scale < 0.999 { exiting += 1 }
        }
        #expect(exiting >= 3)
    }

    // MARK: - `effect_slot.rs:253, 282, 311, 429`

    private func makeSolidRedHook(_ renderer: MetalRenderer) throws -> EffectHook {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 solid_red_vs(uint vid [[vertex_id]]) {
            float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            return float4(pos[vid], 0.0, 1.0);
        }
        fragment float4 solid_red_fs(constant float &isSrgb [[buffer(0)]]) {
            float3 rgb = float3(1.0, 0.0, 0.0);
            return float4(rgb, 1.0);
        }
        """
        let lib = try renderer.device.makeLibrary(source: src, options: nil)
        let vs = lib.makeFunction(name: "solid_red_vs")!
        let fs = lib.makeFunction(name: "solid_red_fs")!
        let cache = LockedBox<[MTLPixelFormat: MTLRenderPipelineState]>([:])
        return { enc, site in
            let pso = cache.withLock { map -> MTLRenderPipelineState in
                if let p = map[site.pixelFormat] { return p }
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = vs
                d.fragmentFunction = fs
                d.colorAttachments[0].pixelFormat = site.pixelFormat
                let p = try! renderer.device.makeRenderPipelineState(descriptor: d)
                map[site.pixelFormat] = p
                return p
            }
            var flag: Float = site.srgbBlend ? 1 : 0
            enc.setRenderPipelineState(pso)
            enc.setFragmentBytes(&flag, length: MemoryLayout<Float>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    @Test("opaque_effects_match_across_blend_modes (effect_slot.rs:253)")
    func opaqueEffectsMatchAcrossBlendModes() throws {
        let renderer = try MetalRenderer()
        let hook = try makeSolidRedHook(renderer)
        let bg = Color(r: 32.0 / 255.0, g: 32.0 / 255.0, b: 32.0 / 255.0, a: 1)
        struct S {}
        func render(srgb: Bool) throws -> Frame {
            let rt = Runtime<S>(
                state: S(),
                viewport: Vec2(96, 96),
                pixelScale: 1.0,
                view: { _, _ in
                    el().size(96, 96).bg(bg).child(el().absolute(x: 16, y: 16).size(64, 64).effect(1))
                }
            )
            rt.setSrgbBlend(srgb)
            return try renderer.renderOffscreen(rt.renderFrame(at: 0), hook: hook)
        }
        let lin = try render(srgb: false)
        let gam = try render(srgb: true)
        let worst = zip(lin.rgba, gam.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2)
        let c = lin.pixel(x: 48, y: 48)
        #expect(c.x >= 253 && c.y <= 2 && c.z <= 2)
    }

    @Test("a_faded_slot_is_faded_for_the_compositor (effect_slot.rs:282)")
    func fadedSlotIsFadedForCompositor() throws {
        let renderer = try MetalRenderer()
        let hook = try makeSolidRedHook(renderer)
        let bgLinVal: Float = Self.srgbDecode(32.0 / 255.0)
        let bg = Color(r: bgLinVal, g: bgLinVal, b: bgLinVal, a: 1)
        struct S {}
        func expectedOver(a: Float, srgb: Bool) -> [UInt8] {
            let b: Float = 32.0 / 255.0
            let rLin: Float = a * 1.0 + (1.0 - a) * bgLinVal
            let gLin: Float = (1.0 - a) * bgLinVal
            if srgb {
                return [
                    UInt8(((a * 1.0 + (1.0 - a) * b) * 255.0).rounded()),
                    UInt8((((1.0 - a) * b) * 255.0).rounded()),
                    UInt8((((1.0 - a) * b) * 255.0).rounded()),
                ]
            } else {
                return [
                    UInt8((Self.srgbEncode(rLin) * 255.0).rounded()),
                    UInt8((Self.srgbEncode(gLin) * 255.0).rounded()),
                    UInt8((Self.srgbEncode(gLin) * 255.0).rounded()),
                ]
            }
        }

        for srgb in [false, true] {
            let views: [(String, El<S>)] = [
                ("leaf", el().size(96, 96).bg(bg).child(el().absolute(x: 16, y: 16).size(64, 64).effect(1).opacity(0.5))),
                ("only-child", el().size(96, 96).bg(bg).child(el().absolute(x: 16, y: 16).size(64, 64).opacity(0.5).child(el().size(64, 64).effect(1)))),
                ("rounded", el().size(96, 96).bg(bg).child(el().absolute(x: 16, y: 16).size(64, 64).clipRounded(24).child(el().size(64, 64).effect(1).opacity(0.5)))),
            ]
            for (name, root) in views {
                let rt = Runtime<S>(state: S(), viewport: Vec2(96, 96), pixelScale: 1.0, view: { _, _ in root })
                rt.setSrgbBlend(srgb)
                let out = try renderer.renderOffscreen(rt.renderFrame(at: 0), hook: hook)
                let pMid = out.pixel(x: 48, y: 48)
                let pOut = out.pixel(x: 8, y: 8)
                #expect(Self.approxRGBA([pMid.x, pMid.y, pMid.z], expectedOver(a: 0.5, srgb: srgb), tol: 3), "\(name) srgb=\(srgb) mid=\(pMid)")
                #expect(Self.approxRGBA([pOut.x, pOut.y, pOut.z], expectedOver(a: 0.0, srgb: srgb), tol: 2), "\(name) srgb=\(srgb) out=\(pOut)")
                if name == "rounded" {
                    let pCorner = out.pixel(x: 17, y: 17)
                    #expect(Self.approxRGBA([pCorner.x, pCorner.y, pCorner.z], expectedOver(a: 0.0, srgb: srgb), tol: 2))
                }
            }
        }
    }

    @Test("an_unpainted_effect_slot_draws_nothing (effect_slot.rs:311)")
    func unpaintedEffectSlotDrawsNothing() throws {
        let renderer = try MetalRenderer()
        let bg = Color(r: 0.2, g: 0.2, b: 0.2, a: 1)
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(96, 96),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(96, 96).bg(bg).child(el().absolute(x: 16, y: 16).size(64, 64).effect(1))
            }
        )
        rt.setSrgbBlend(false)
        var slots = 0
        let out = try renderer.renderOffscreen(rt.renderFrame(at: 0), hook: { _, _ in
            slots += 1
        })
        #expect(slots == 1)
        let grey = out.pixel(x: 8, y: 8)
        for (x, y) in [(16, 16), (48, 48), (79, 79)] {
            #expect(out.pixel(x: x, y: y) == grey)
        }
    }

    @Test("inert_backdrop_slots_draw_but_hidden_and_offscreen_subtrees_do_not (effect_slot.rs:429)")
    func inertBackdropSlotsDrawHiddenAndOffscreenDoNot() throws {
        let renderer = try MetalRenderer()
        let bg = Color(r: 0.15, g: 0.15, b: 0.15, a: 1)
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(96, 96),
            pixelScale: 1.0,
            view: { _, _ in
                el().size(96, 96).bg(bg)
                    .child(el().inert().absolute(x: 8, y: 8).size(24, 24).child(el().size(24, 24).effect(1).effectBackdrop(true)))
                    .child(el().absolute(x: 200, y: 200).size(24, 24).child(el().size(24, 24).effect(2).effectBackdrop(true)))
                    .child(el().opacity(0.0).absolute(x: 40, y: 8).size(24, 24).child(el().size(24, 24).effect(3).effectBackdrop(true)))
            }
        )
        rt.setSrgbBlend(false)
        var events: [(UInt32, String, Bool, Bool)] = []
        _ = try renderer.renderOffscreen(rt.renderFrame(at: 0), backdropHook: { phase, site in
            let pName = switch phase {
            case .backdrop: "backdrop"
            case .draw: "draw"
            }
            events.append((site.mark, pName, site.backdrop != nil, site.inLayer))
        })
        #expect(events.count == 2)
        if events.count == 2 {
            #expect(events[0] == (1, "backdrop", true, false))
            #expect(events[1] == (1, "draw", true, false))
        }
    }

    #endif
}
