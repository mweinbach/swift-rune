import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore

@Suite("Render Clip, Backdrop, Alpha & BorderDash Parity Tests")
struct RenderClipBackdropDashTests {
    private func sampleRGBA(_ frame: Frame, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cx = max(0, min(frame.width - 1, x))
        let cy = max(0, min(frame.height - 1, y))
        let off = (cy * frame.width + cx) * 4
        return (frame.rgba[off], frame.rgba[off + 1], frame.rgba[off + 2], frame.rgba[off + 3])
    }

    private func stripes<State>(_ w: Float, _ h: Float, stripeWidth: Float = 4) -> El<State> {
        let count = Int(ceil(w / stripeWidth))
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let blue = Color(r: 0, g: 0, b: 1, a: 1)
        return row().size(w, h).children(
            (0..<count).map { i in
                el().size(stripeWidth, h).bg(i.isMultiple(of: 2) ? red : blue)
            }
        )
    }

    // MARK: - Group 1: tests/clip.rs (6 tests)

    /// Upstream: `crates/rune/tests/clip.rs:37` `overflowing_scroll_content_stays_inside_the_box_as_it_scrolls`
    @Test("clip.rs:37 overflowing_scroll_content_stays_inside_the_box_as_it_scrolls")
    func overflowingScrollContentStaysInsideBoxAsItScrolls() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let rt = Runtime<S>(state: S(), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40).bg(.black)
                .child(
                    col().key("scroll").size(20, 20).scrollY().scrollEdgeFade(0).clip()
                        .child(el().key("tall").size(20, 80).bg(red))
                )
        }
        rt.clearColor = .black

        let rf0 = rt.renderFrame(at: 0.0)
        // Tall child primitive is clipped tightly to [0, 0, 20, 20] and has no unrequested fade (fade.z == 0)
        let tallInst0 = try #require(rf0.instances.last(where: { $0.params.y == KIND_RECT && $0.fill.x > 0.9 }))
        #expect(tallInst0.clip == SIMD4<Float>(0, 0, 20, 20))
        #expect(tallInst0.fade.z == 0)

        let img0 = try renderer.renderOffscreen(rf0)
        #expect(sampleRGBA(img0, x: 10, y: 10).r > 240)
        #expect(sampleRGBA(img0, x: 10, y: 10).g < 10)
        #expect(sampleRGBA(img0, x: 30, y: 10).r < 10)
        #expect(sampleRGBA(img0, x: 10, y: 30).r < 10)

        // Scroll down and verify content remains strictly clipped to [0, 0, 20, 20]
        rt.wheel(WheelEvent(dx: 0, dy: -20), at: Vec2(10, 10), now: 0.1)
        let rf1 = rt.renderFrame(at: 0.1)
        let tallInst1 = try #require(rf1.instances.last(where: { $0.params.y == KIND_RECT && $0.fill.x > 0.9 }))
        #expect(tallInst1.clip == SIMD4<Float>(0, 0, 20, 20))
        #expect(tallInst1.rect.y < -0.5)

        let img1 = try renderer.renderOffscreen(rf1)
        #expect(sampleRGBA(img1, x: 10, y: 10).r > 240)
        #expect(sampleRGBA(img1, x: 30, y: 10).r < 10)
        #expect(sampleRGBA(img1, x: 10, y: 30).r < 10)

        // Opened at the bottom with stickBottom: true, top overflow is clipped above [0, 0, 20, 20] too
        let rtStick = Runtime<S>(state: S(), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40).bg(.black)
                .child(el().size(40, 10))
                .child(
                    col().key("scroll").size(20, 20).scrollY(stickBottom: true).scrollEdgeFade(0).clip()
                        .child(el().key("top").size(20, 40).bg(red))
                        .child(el().key("bot").size(20, 40).bg(red))
                )
        }
        rtStick.clearColor = .black
        let rfStick = rtStick.renderFrame(at: 0.0)
        let imgStick = try renderer.renderOffscreen(rfStick)
        #expect(sampleRGBA(imgStick, x: 10, y: 15).r > 240)
        #expect(sampleRGBA(imgStick, x: 10, y: 5).r < 10) // content scrolled above box y=10 isn't drawn
        #expect(sampleRGBA(imgStick, x: 10, y: 35).r < 10) // below box y=30 isn't drawn
    }

    /// Upstream: `crates/rune/tests/clip.rs:64` `a_press_outside_the_box_misses_clipped_content`
    @Test("clip.rs:64 a_press_outside_the_box_misses_clipped_content")
    func pressOutsideBoxMissesClippedContent() {
        struct S { var hits = 0 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40)
                .child(
                    col().size(20, 20).clip()
                        .child(
                            el().key("btn").size(40, 40)
                                .onClick { s, _ in s.hits += 1 }
                        )
                )
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "btn")?.visible == [0, 0, 20, 20])

        // Press inside the 20x20 clip box hits
        rt.pointerMove(to: Vec2(10, 10), at: 0.01)
        rt.pointerDown(at: Vec2(10, 10), button: .primary, at: 0.01)
        rt.pointerUp(at: Vec2(10, 10), button: .primary, at: 0.02)
        #expect(rt.state.hits == 1)

        // Press at (30, 10): inside child's 40x40 layout rect, but outside parent's 20x20 clip -> must miss
        rt.pointerMove(to: Vec2(30, 10), at: 0.03)
        rt.pointerDown(at: Vec2(30, 10), button: .primary, at: 0.03)
        rt.pointerUp(at: Vec2(30, 10), button: .primary, at: 0.04)
        #expect(rt.state.hits == 1)
    }

    /// Upstream: `crates/rune/tests/clip.rs:78` `an_explicit_soft_clip_still_wins`
    @Test("clip.rs:78 an_explicit_soft_clip_still_wins")
    func explicitSoftClipStillWins() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let rt = Runtime<S>(state: S(), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40).bg(.black)
                .child(
                    col().size(24, 24).clip().clipSoft(6)
                        .child(el().size(24, 60).bg(red))
                )
        }
        rt.clearColor = .black

        let rf = rt.renderFrame(at: 0.0)
        // Look at the packed fade on the soft-clipped layer/instance: all 4 edges preserve explicit fade width 6
        let faded = try #require(rf.instances.first(where: { $0.fade.z != 0 || ($0.fade.x != 0 || $0.fade.y != 0) }))
        let decoded = unpackFade(faded.fade)
        #expect(abs(decoded.width.x - 6.0) < 0.25)
        #expect(abs(decoded.width.y - 6.0) < 0.25)
        #expect(abs(decoded.width.z - 6.0) < 0.25)
        #expect(abs(decoded.width.w - 6.0) < 0.25)

        let img = try renderer.renderOffscreen(rf)
        // Edge pixel at (1, 12) is attenuated below center (12, 12)
        let edgePx = sampleRGBA(img, x: 1, y: 12)
        let midPx = sampleRGBA(img, x: 12, y: 12)
        #expect(edgePx.r > 0 && edgePx.r < 120)
        #expect(midPx.r > 240)
        // Outside box stays black
        #expect(sampleRGBA(img, x: 30, y: 12).r < 5)
    }

    /// Upstream: `crates/rune/tests/clip.rs:90` `packed_fades_survive_group_layer_projection_without_double_application`
    @Test("clip.rs:90 packed_fades_survive_group_layer_projection_without_double_application")
    func packedFadesSurviveGroupLayerProjectionWithoutDoubleApplication() throws {
        let renderer = try MetalRenderer()
        struct S {}

        for (scale, rounded): (Float, Float) in [(1.0, 0.0), (1.0, 10.0), (2.0, 0.0), (2.0, 10.0)] {
            // 1. Group layer (opacity 0.5 with multiple children so KIND_LAYER stays isolated) inside faded ancestor
            let rtLayer = Runtime<S>(state: S(), viewport: Vec2(64, 64), pixelScale: scale) { _, _ in
                var outer: El<S> = col().size(48, 48).clip().clipFade(left: 16)
                if rounded > 0 { outer = outer.clipRounded(rounded) }
                return col().size(64, 64).bg(.black)
                    .child(
                        outer.child(
                            col().size(48, 48).opacity(0.5)
                                .children([
                                    el().size(48, 24).bg(.white),
                                    el().size(48, 24).bg(.white),
                                ])
                        )
                    )
            }
            rtLayer.clearColor = .black

            // 2. Direct single-fade baseline without nested opacity group wrapper
            let rtDirect = Runtime<S>(state: S(), viewport: Vec2(64, 64), pixelScale: scale) { _, _ in
                var outer: El<S> = col().size(48, 48).clip().clipFade(left: 16)
                if rounded > 0 { outer = outer.clipRounded(rounded) }
                return col().size(64, 64).bg(.black)
                    .child(
                        outer.children([
                            el().size(48, 24).bg(Color.white.alpha(0.5)),
                            el().size(48, 24).bg(Color.white.alpha(0.5)),
                        ])
                    )
            }
            rtDirect.clearColor = .black

            let rfLayer = rtLayer.renderFrame(at: 0.0)
            // Verify packed fade stays on outer scope and inner primitives inside KIND_LAYER do not re-apply it
            var layerDepth = 0
            var sawLayerWithFade = false
            for inst in rfLayer.instances {
                if inst.params.y == KIND_LAYER {
                    if unpackFade(inst.fade).width.x > 1.0 {
                        sawLayerWithFade = true
                    }
                    layerDepth += 1
                } else if inst.params.y == KIND_LAYER_END {
                    layerDepth = max(0, layerDepth - 1)
                } else if layerDepth >= 2 && inst.params.y == KIND_RECT {
                    #expect(unpackFade(inst.fade).width == .zero)
                }
            }
            #expect(sawLayerWithFade)

            let imgLayer = try renderer.renderOffscreen(rfLayer)
            let imgDirect = try renderer.renderOffscreen(rtDirect.renderFrame(at: 0.0))

            // Sample along horizontal mid-line inside the 16pt left fade zone
            for xPt in [4, 8, 12, 24] {
                let px = Int((Float(xPt) * scale).rounded())
                let py = Int((24.0 * scale).rounded())
                let a = sampleRGBA(imgLayer, x: px, y: py)
                let b = sampleRGBA(imgDirect, x: px, y: py)
                #expect(abs(Int(a.r) - Int(b.r)) <= 3, "scale=\(scale) rounded=\(rounded) x=\(xPt): layer=\(a.r) vs direct=\(b.r)")
            }
        }
    }

    /// Upstream: `crates/rune/tests/clip.rs:122` `narrower_nested_edge_and_streaming_mask_survive_outer_fades`
    @Test("clip.rs:122 narrower_nested_edge_and_streaming_mask_survive_outer_fades")
    func narrowerNestedEdgeAndStreamingMaskSurviveOuterFades() throws {
        let renderer = try MetalRenderer()

        // Part A: Narrower inner clipFade survives outer clipFade without getting erased
        struct ClipS {}
        let rtNested = Runtime<ClipS>(state: ClipS(), viewport: Vec2(80, 60), pixelScale: 1.0) { _, _ in
            col().size(80, 60).bg(.black)
                .child(
                    col().size(80, 60).clip().clipFade(left: 24)
                        .child(
                            col().size(60, 60).clip().clipFade(top: 10)
                                .child(el().size(60, 60).bg(.white))
                        )
                )
        }
        rtNested.clearColor = .black
        let rfNested = rtNested.renderFrame(at: 0.0)
        // Outer fade (left: 24) and narrower inner fade (top: 10) must BOTH appear across instances/layers
        let widths = rfNested.instances.map { unpackFade($0.fade).width }
        #expect(widths.contains(where: { abs($0.x - 24.0) < 0.5 }))
        #expect(widths.contains(where: { abs($0.y - 10.0) < 0.5 }))

        let imgNested = try renderer.renderOffscreen(rfNested)
        // (40, 2) is inside outer non-faded x-range [24..80] but inside inner top fade [0..10] -> attenuated
        #expect(sampleRGBA(imgNested, x: 40, y: 2).r < 120)
        // (6, 30) is inside outer left fade [0..24] -> attenuated
        #expect(sampleRGBA(imgNested, x: 6, y: 30).r < 120)
        // (40, 30) is clear of both fades -> bright white
        #expect(sampleRGBA(imgNested, x: 40, y: 30).r > 245)

        // Part B: Streaming/growth feather row inside an outer clipFade preserves both streaming mask & outer fade across 1x & 2x
        struct StreamS { var h: Float = 20 }
        for scale: Float in [1.0, 2.0] {
            let renderStreaming: (Bool) throws -> (Frame, RenderFrame) = { faded in
                let rtStream = Runtime<StreamS>(state: StreamS(), viewport: Vec2(80, 200), pixelScale: scale) { s, _ in
                    col().size(80, 200).clipFade(bottom: faded ? 24 : 0)
                        .child(
                            col().wFull().growth(GrowthSpec(edge: .fastFeather))
                                .child(
                                    col().key("row").wFull().streaming(true)
                                        .child(el().size(80, s.h).bg(.white))
                                )
                        )
                }
                rtStream.clearColor = .black
                _ = rtStream.renderFrame(at: 0.0)
                rtStream.update(at: 0.0) { s, _ in s.h = 80 }
                _ = rtStream.renderFrame(at: 1.0 / 60.0)
                let rf = rtStream.renderFrame(at: 2.0 / 60.0)
                let img = try renderer.renderOffscreen(rf)
                return (img, rf)
            }
            let (imgPlain, _) = try renderStreaming(false)
            let (imgFaded, rfFaded) = try renderStreaming(true)
            let rowInst = try #require(rfFaded.instances.first(where: { $0.fill.w > 0.99 }))
            let (rowWidth, rowOffset) = unpackFade(rowInst.fade)
            #expect(rowWidth.w > 0 && rowWidth.w < 24.0 * scale)
            #expect(rowOffset.w == 0.0)
            #expect(imgPlain.rgba == imgFaded.rgba)
        }
    }

    /// Upstream: `crates/rune/tests/clip.rs:204` `a_linear_fade_falls_in_proportion_to_distance_from_the_edge`
    @Test("clip.rs:204 a_linear_fade_falls_in_proportion_to_distance_from_the_edge")
    func linearFadeFallsInProportionToDistanceFromEdge() throws {
        let renderer = try MetalRenderer()

        // 1. CPU RefScene path via Runtime.frame(at:)
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(60, 20), pixelScale: 1.0) { _, _ in
            col().size(60, 20).bg(.black)
                .child(
                    col().size(60, 20).clip().clipFadeLinear(left: 20)
                        .child(el().size(60, 20).bg(.white))
                )
        }
        rt.clearColor = .black
        let scene = rt.frame(at: 0.0)
        // RefScene encodes directional linear fade [dirX=1, dirY=0, invSpan=1/20, minAlpha=0]
        #expect(scene.primitives.contains { abs($0.fade.z - 0.05) < 0.002 && $0.fade.x == 1.0 })
        let cpuImg = try RuneRef.render(scene)
        let c3 = cpuImg.pixel(x: 3, y: 10).x
        let c9 = cpuImg.pixel(x: 9, y: 10).x
        let c15 = cpuImg.pixel(x: 15, y: 10).x
        let c30 = cpuImg.pixel(x: 30, y: 10).x
        #expect(c3 > 30 && c3 < 70)
        #expect(abs(Int(c9) - 121) < 12)
        #expect(c15 > 180 && c15 < 220)
        #expect(c30 > 250)

        // 2. Runtime.renderFrame(at:) packs negative -20 width and Metal renders the linear ramp directly
        let rf = rt.renderFrame(at: 0.0)
        let fadedInst = try #require(rf.instances.first(where: { unpackFade($0.fade).width.x < 0 }))
        #expect(abs(unpackFade(fadedInst.fade).width.x - (-20.0)) < 0.05)
        let gpuImg = try renderer.renderOffscreen(rf)
        let g3 = sampleRGBA(gpuImg, x: 3, y: 10).r
        let g9 = sampleRGBA(gpuImg, x: 9, y: 10).r
        let g15 = sampleRGBA(gpuImg, x: 15, y: 10).r
        let g30 = sampleRGBA(gpuImg, x: 30, y: 10).r
        #expect(abs(Double(g3) - 255.0 * (3.5 / 20.0)) < 4.0)
        #expect(abs(Double(g9) - 255.0 * (9.5 / 20.0)) < 4.0)
        #expect(abs(Double(g15) - 255.0 * (15.5 / 20.0)) < 4.0)
        #expect(g30 == 255)
    }

    // MARK: - Group 2: tests/backdrop_blur.rs (4) + backdrop_tests.rs:7 + surface_alpha.rs:14 (6 tests)

    /// Upstream: `crates/rune/tests/backdrop_blur.rs:103` `without_backdrop_blur_the_frame_is_unchanged`
    @Test("backdrop_blur.rs:103 without_backdrop_blur_the_frame_is_unchanged")
    func withoutBackdropBlurFrameIsUnchanged() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let tint = Color(r: 0, g: 1, b: 0, a: 0.4)
        let rtZero = Runtime<S>(state: S(), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40)
                .child(stripes(40, 40))
                .child(el().size(20, 20).absolute(x: 10, y: 10).bg(tint).backdropBlur(0))
        }
        let rtNone = Runtime<S>(state: S(), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40)
                .child(stripes(40, 40))
                .child(el().size(20, 20).absolute(x: 10, y: 10).bg(tint))
        }
        let rfZero = rtZero.renderFrame(at: 0.0)
        let rfNone = rtNone.renderFrame(at: 0.0)
        #expect(!rfZero.instances.contains { $0.params.y == KIND_BACKDROP_BLUR })
        #expect(rfZero.instances == rfNone.instances)

        let imgZero = try renderer.renderOffscreen(rfZero)
        let imgNone = try renderer.renderOffscreen(rfNone)
        #expect(imgZero.rgba == imgNone.rgba)
    }

    private func bwStripes<State>(_ w: Float, _ h: Float, stripeWidth: Float = 4) -> El<State> {
        let count = Int(ceil(w / stripeWidth))
        return row().size(w, h).absolute(x: 0, y: 0).children(
            (0..<count).map { i in
                el().size(stripeWidth, h).bg(i.isMultiple(of: 2) ? .black : .white)
            }
        )
    }

    private func redSpread(_ frame: Frame, y: Int, x0: Int, x1: Int) -> Int {
        var lo = 255
        var hi = 0
        for x in x0..<x1 {
            let r = Int(sampleRGBA(frame, x: x, y: y).r)
            lo = min(lo, r)
            hi = max(hi, r)
        }
        return hi - lo
    }

    /// Upstream: `crates/rune/tests/backdrop_blur.rs:113` `two_bars_each_blur_their_own_backdrop`
    @Test("backdrop_blur.rs:113 two_bars_each_blur_their_own_backdrop")
    func twoBarsEachBlurTheirOwnBackdrop() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let redHalf = Color(r: 1, g: 0, b: 0, a: 0.5)
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col().size(200, 120)
                .child(bwStripes(200, 120))
                .child(el().size(70, 60).absolute(x: 10, y: 30).rounded(16).backdropBlur(8))
                .child(el().size(70, 60).absolute(x: 120, y: 30).rounded(16).bg(redHalf).backdropBlur(8))
        }
        rt.clearColor = .black
        let rf = rt.renderFrame(at: 0.0)
        let blurs = rf.instances.filter { $0.params.y == KIND_BACKDROP_BLUR }
        #expect(blurs.count == 2)

        let img = try renderer.renderOffscreen(rf)
        #expect(redSpread(img, y: 60, x0: 25, x1: 65) <= 3)
        #expect(redSpread(img, y: 60, x0: 135, x1: 175) <= 3)
        #expect(redSpread(img, y: 60, x0: 85, x1: 115) > 200)
        let tinted = sampleRGBA(img, x: 155, y: 60)
        #expect(Int(tinted.r) > Int(tinted.g) + 60)
    }

    /// Upstream: `crates/rune/tests/backdrop_blur.rs:136` `a_faded_bar_blurs_the_window_not_its_own_layer`
    @Test("backdrop_blur.rs:136 a_faded_bar_blurs_the_window_not_its_own_layer")
    func fadedBarBlursWindowNotOwnLayer() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col().size(200, 120)
                .child(bwStripes(200, 120))
                .child(
                    el().size(120, 60).absolute(x: 40, y: 30)
                        .rounded(16)
                        .opacity(0.5)
                        .backdropBlur(8)
                        .bg(Color.white.alpha(0.2))
                        .child(el().size(10, 10).bg(.white))
                )
        }
        rt.clearColor = .black
        let rf = rt.renderFrame(at: 0.0)
        let blurIdx = try #require(rf.instances.firstIndex(where: { $0.params.y == KIND_BACKDROP_BLUR }))
        #expect(abs(rf.instances[blurIdx].fill.w - 0.5) < 0.01)
        let layerIdx = try #require(rf.instances.firstIndex(where: { $0.params.y == KIND_LAYER }))
        #expect(blurIdx < layerIdx)

        let img = try renderer.renderOffscreen(rf)
        let s = redSpread(img, y: 60, x0: 60, x1: 140)
        #expect((40..<200).contains(s))
    }

    /// Upstream: `crates/rune/tests/backdrop_blur.rs:191` `scrolled_content_changes_the_blur_and_a_still_frame_stays_idle`
    @Test("backdrop_blur.rs:191 scrolled_content_changes_the_blur_and_a_still_frame_stays_idle")
    func scrolledContentChangesBlurAndStillFrameStaysIdle() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let blue = Color(r: 0, g: 0, b: 1, a: 1)
        let rt = Runtime<S>(state: S(), viewport: Vec2(80, 80), pixelScale: 1.0) { _, _ in
            col().size(80, 80)
                .child(
                    col().key("list").size(80, 80).scrollY().scrollEdgeFade(0).clip()
                        .children([
                            el().size(80, 40).bg(red),
                            el().size(80, 80).bg(blue),
                        ])
                )
                .child(
                    el().size(80, 32).absolute(x: 0, y: 0)
                        .backdropBlur(12)
                        .bg(Color.white.alpha(0.05))
                )
        }

        let rf0 = rt.renderFrame(at: 0.0)
        let commitsAfter0 = rt.viewCommitCount
        #expect(rt.hasPendingCommit == false)
        #expect(rt.isAnimating == false)
        let img0 = try renderer.renderOffscreen(rf0)
        let pxBefore = sampleRGBA(img0, x: 40, y: 16)
        #expect(pxBefore.r > pxBefore.b)

        // Still frame with no input does not stay dirty or keep committing
        let rfIdle = rt.renderFrame(at: 0.05)
        #expect(rt.hasPendingCommit == false)
        #expect(rt.viewCommitCount == commitsAfter0)
        #expect(rfIdle.instances == rf0.instances)

        // Scroll blue block up under the blurred bar -> blurred pixels shift from red-dominant to blue-dominant
        rt.wheel(WheelEvent(dx: 0, dy: -40), at: Vec2(40, 50), now: 0.1)
        let rf1 = rt.renderFrame(at: 0.1)
        let img1 = try renderer.renderOffscreen(rf1)
        let pxAfter = sampleRGBA(img1, x: 40, y: 16)
        #expect(pxAfter.b > pxAfter.r)
        #expect(abs(Int(pxAfter.b) - Int(pxBefore.b)) > 80)
        #expect(rt.hasPendingCommit == false)
    }

    /// Upstream: `crates/rune/src/render/backdrop_tests.rs:7` `backdrop_pool_is_lazy_reused_resized_and_follows_live_formats`
    @Test("backdrop_tests.rs:7 backdrop_pool_is_lazy_reused_resized_and_follows_live_formats")
    func backdropPoolIsLazyReusedResizedAndFollowsLiveFormats() throws {
        let renderer = try MetalRenderer()
        let emptyAtlas = GlyphAtlas().compositedAtlas()

        func makeEffectFrame(width: Int, height: Int, srgbBlend: Bool, instances: [RenderInstance]) -> RenderFrame {
            RenderFrame(
                width: width,
                height: height,
                srgbBlend: srgbBlend,
                clearColor: SIMD4<Float>(0, 0, 0, 1),
                glyphs: emptyAtlas,
                glyphGeneration: 0,
                images: RGBA8Atlas(),
                imageRevision: 0,
                instances: instances
            )
        }

        // 1. Empty & ordinary effect slots (params.x == 0) allocate 0 backdrop textures
        var slot = RenderInstance(
            rect: SIMD4<Float>(0, 0, 16, 16),
            fill: SIMD4<Float>(0, 0, 0, 1),
            params: SIMD4<Float>(0, KIND_EFFECT, 0, 1),
            clip: NO_CLIP
        )
        for instances in [[], [slot]] {
            renderer.prepare(frame: makeEffectFrame(width: 32, height: 32, srgbBlend: false, instances: instances), viewport: (32, 32))
            #expect(renderer.backdropTextures.isEmpty)
        }

        // 2. Slot requesting backdrop allocates 1 texture and reuses the exact texture object on repeat prepare
        slot.params.x = 1.0
        renderer.setFormat(.bgra8Unorm_srgb)
        let oneSlot = makeEffectFrame(width: 32, height: 32, srgbBlend: false, instances: [slot])
        renderer.prepare(frame: oneSlot, viewport: (32, 32))
        #expect(renderer.backdropTextures.count == 1)
        let original = renderer.backdropTextures[0]
        renderer.prepare(frame: oneSlot, viewport: (32, 32))
        #expect(renderer.backdropTextures[0] === original)

        // 3. Switching format after prepare allocates/ensures the new format's pool immediately
        renderer.setFormat(.bgra8Unorm)
        #expect(renderer.backdropTextures.contains(where: { $0.pixelFormat == .bgra8Unorm }))

        // 4. Two slots [slot, slot] across format/size transitions share one texture per draw & keep 2 format pools
        let twoSlots = makeEffectFrame(width: 32, height: 32, srgbBlend: false, instances: [slot, slot])
        for (fmt, size) in [(MTLPixelFormat.bgra8Unorm, (48, 24)), (.bgra8Unorm_srgb, (24, 48)), (.bgra8Unorm, (32, 32))] {
            renderer.setFormat(fmt)
            let frameForSize = makeEffectFrame(width: size.0, height: size.1, srgbBlend: fmt == .bgra8Unorm, instances: twoSlots.instances)
            renderer.prepare(frame: frameForSize, viewport: size)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: size.0, height: size.1, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            let target = try #require(renderer.device.makeTexture(descriptor: desc))
            let cb = try #require(renderer.commandQueue.makeCommandBuffer())
            var backdrops: [MTLTexture] = []
            renderer.drawWithBackdrop(frame: frameForSize, into: target, commandBuffer: cb) { phase, site in
                if case .backdrop = phase, let b = site.backdrop {
                    #expect((b.width, b.height) == size)
                    #expect(b.pixelFormat == fmt)
                    backdrops.append(b)
                }
            }
            cb.commit()
            cb.waitUntilCompleted()
            #expect(backdrops.count == 2)
            #expect(backdrops[0] === backdrops[1])
            #expect(renderer.backdropTextures.count == 2)
        }
    }

    /// Upstream: `crates/rune/src/render/surface_alpha.rs:14` `gpu_straight_alpha_matches_cpu_reference`
    @Test("surface_alpha.rs:14 gpu_straight_alpha_matches_cpu_reference")
    func gpuStraightAlphaMatchesCpuReference() throws {
        let renderer = try MetalRenderer()
        let emptyAtlas = GlyphAtlas().compositedAtlas()

        // Match upstream premultiplied clear colors: half-transparent teal, fully transparent, opaque color
        let clears: [SIMD4<Float>] = [
            SIMD4<Float>(0.125, 0.25, 0.375, 0.5),
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0.4, 0.6, 0.1, 1.0),
        ]

        func expectedStraight(_ premulLinear: SIMD4<Float>, srgbBlend: Bool) -> [UInt8] {
            let a = premulLinear.w
            if a <= 0 {
                return [0, 0, 0, 0]
            }
            let aByte = UInt8((a * 255.0).rounded())
            if srgbBlend {
                // Direct linear unorm8 unpremultiplication matching MetalRenderer.renderOffscreen srgbBlend=true
                let rf = min(255.0, (Float(UInt8((premulLinear.x * 255.0).rounded())) / (Float(aByte) / 255.0)).rounded())
                let gf = min(255.0, (Float(UInt8((premulLinear.y * 255.0).rounded())) / (Float(aByte) / 255.0)).rounded())
                let bf = min(255.0, (Float(UInt8((premulLinear.z * 255.0).rounded())) / (Float(aByte) / 255.0)).rounded())
                return [UInt8(rf), UInt8(gf), UInt8(bf), aByte]
            }
            // Linear -> sRGB encoded premul bytes -> HeadlessRunner.straightAlpha CPU reference
            var px: [UInt8] = [
                UInt8((RefShader.linearToSRGB(premulLinear.x) * 255.0).rounded()),
                UInt8((RefShader.linearToSRGB(premulLinear.y) * 255.0).rounded()),
                UInt8((RefShader.linearToSRGB(premulLinear.z) * 255.0).rounded()),
                aByte,
            ]
            HeadlessRunner.straightAlpha(&px)
            return px
        }

        for srgbBlend in [false, true] {
            for clear in clears {
                let rf = RenderFrame(
                    width: 4,
                    height: 4,
                    srgbBlend: srgbBlend,
                    clearColor: clear,
                    glyphs: emptyAtlas,
                    glyphGeneration: 0,
                    images: RGBA8Atlas(),
                    imageRevision: 0,
                    instances: []
                )
                let frame = try renderer.renderOffscreen(rf)
                let want = expectedStraight(clear, srgbBlend: srgbBlend)
                for y in 0..<4 {
                    for x in 0..<4 {
                        let got = sampleRGBA(frame, x: x, y: y)
                        #expect(abs(Int(got.r) - Int(want[0])) <= 1, "clear=\(clear) srgbBlend=\(srgbBlend) R got=\(got.r) want=\(want[0])")
                        #expect(abs(Int(got.g) - Int(want[1])) <= 1, "clear=\(clear) srgbBlend=\(srgbBlend) G got=\(got.g) want=\(want[1])")
                        #expect(abs(Int(got.b) - Int(want[2])) <= 1, "clear=\(clear) srgbBlend=\(srgbBlend) B got=\(got.b) want=\(want[2])")
                        #expect(abs(Int(got.a) - Int(want[3])) <= 1, "clear=\(clear) srgbBlend=\(srgbBlend) A got=\(got.a) want=\(want[3])")
                    }
                }
            }
        }
    }

    // MARK: - Group 3: tests/border_dash.rs (2 tests)

    private enum CapsuleMode {
        case solid
        case dashed
        case filledDashed
        case gradientDashed
    }

    private func makeCapsuleFrame(mode: CapsuleMode, pixelScale: Float = 2.0) -> RenderFrame {
        struct S {}
        let top = Color.rgba8(255, 0, 0, 255)
        let bottom = Color.rgba8(0, 0, 255, 255)
        let rim = Color.rgba8(255, 255, 255, 255)
        let dark = Color.rgba8(18, 22, 28, 255)
        let rt = Runtime<S>(state: S(), viewport: Vec2(68, 22), pixelScale: pixelScale) { _, _ in
            var card: El<S> = el().size(60, 14).absolute(x: 4, y: 4).rounded(7)
            switch mode {
            case .solid:
                card = card.border(1.0, rim)
            case .dashed:
                card = card.dashedBorder(1.0, rim, dash: 8, gap: 4)
            case .filledDashed:
                card = card.bg(dark).dashedBorder(1.0, rim, dash: 8, gap: 4, phase: 2.0)
            case .gradientDashed:
                card = card.borderGradient(width: 1.0, top: top, bottom: bottom).dashedBorder(1.0, rim, dash: 8, gap: 4)
            }
            return col().size(68, 22).child(card)
        }
        var rf = rt.renderFrame(at: 0.0)
        rf.clearColor = .zero
        return rf
    }

    /// Upstream: `crates/rune/tests/border_dash.rs:47` `a_dashed_border_is_its_own_ring_over_the_fill`
    @Test("border_dash.rs:47 a_dashed_border_is_its_own_ring_over_the_fill")
    func dashedBorderIsItsOwnRingOverFill() {
        let dashed = makeCapsuleFrame(mode: .dashed)
        #expect(dashed.instances.count == 1)
        #expect(dashed.instances[0].params.y == KIND_DASHED)
        #expect(dashed.instances[0].params.x == 2.0) // 1pt * scale 2

        let filled = makeCapsuleFrame(mode: .filledDashed)
        #expect(filled.instances.count == 2)
        #expect(filled.instances[0].params.y == KIND_RECT)
        #expect(filled.instances[1].params.y == KIND_DASHED)
        #expect(filled.instances[1].uv == SIMD4<Float>(16, 8, 4, 0)) // (8, 4, 2) * scale 2

        let grad = makeCapsuleFrame(mode: .gradientDashed)
        #expect(grad.instances.count == 1)
        #expect(grad.instances[0].params.y == KIND_DASHED)
        #expect(grad.instances[0].params.x == 2.0)
        #expect(abs(grad.instances[0].fill.x - 1.0) < 1e-4 && abs(grad.instances[0].fill.y) < 1e-4 && abs(grad.instances[0].fill.z) < 1e-4 && grad.instances[0].fill.w == 1.0)
        #expect(abs(grad.instances[0].border.x) < 1e-4 && abs(grad.instances[0].border.y) < 1e-4 && abs(grad.instances[0].border.z - 1.0) < 1e-4 && grad.instances[0].border.w == 1.0)
    }

    /// Upstream: `crates/rune/tests/border_dash.rs:62` `dashes_antialias_like_the_solid_border_and_show_the_fill_between`
    @Test("border_dash.rs:62 dashes_antialias_like_the_solid_border_and_show_the_fill_between")
    func dashesAntialiasLikeSolidBorderAndShowFillBetween() throws {
        let renderer = try MetalRenderer()
        let solid = try renderer.renderOffscreen(makeCapsuleFrame(mode: .solid))
        let dashed = try renderer.renderOffscreen(makeCapsuleFrame(mode: .dashed))
        let filled = try renderer.renderOffscreen(makeCapsuleFrame(mode: .filledDashed))

        // At scale 2, first dash covers x=22..38.1, first gap 38.1..46.2; exact pixel match at x=30 and gap at x=42
        for y in 6..<12 {
            #expect(sampleRGBA(dashed, x: 30, y: y) == sampleRGBA(solid, x: 30, y: y))
            #expect(sampleRGBA(dashed, x: 42, y: y).a == 0)
        }
        #expect(sampleRGBA(solid, x: 30, y: 8).a > 250 && sampleRGBA(solid, x: 30, y: 9).a > 250)

        // Top-right corner arc (centre line radius 13 about (114, 22)): continues from gap into dash
        let corner: [UInt8] = (0...16).map { n in
            let a = Float(n) / 16.0 * (.pi / 2.0)
            return sampleRGBA(dashed, x: Int(114.0 + 13.0 * sin(a)), y: Int(22.0 - 13.0 * cos(a))).a
        }
        #expect(corner[..<2].allSatisfy { $0 == 0 } && corner[6..<14].allSatisfy { $0 > 150 })

        // Filled + phase 2pt (4px) shifts gap to x=38 showing dark fill, while dash draws over fill at x=26
        let dark = sampleRGBA(filled, x: 68, y: 20)
        #expect(dark.a > 250 && dark.r < 100)
        #expect(sampleRGBA(filled, x: 38, y: 8) == dark)
        #expect(sampleRGBA(filled, x: 26, y: 8).r > 250)
    }
}
#endif
