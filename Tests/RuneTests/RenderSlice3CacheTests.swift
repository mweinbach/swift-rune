import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import Rune

@Suite("Slice 3 Layer Cache Parity Tests (layer_cache_tests.rs)")
struct RenderSlice3CacheTests {
    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // MARK: - Helpers (matching layer_cache_tests.rs & layer_tests.rs)

    private func srgbBytes(_ linear: SIMD4<Float>) -> [UInt8] {
        let ch: (Float, Bool) -> UInt8 = { v, isAlpha in
            let srgb: Float
            if isAlpha {
                srgb = v
            } else if v <= 0.0031308 {
                srgb = v * 12.92
            } else {
                srgb = 1.055 * powf(v, 1.0 / 2.4) - 0.055
            }
            let clamped = min(max(srgb, 0), 1)
            return UInt8((clamped * 255.0).rounded())
        }
        return [ch(linear.x, false), ch(linear.y, false), ch(linear.z, false), ch(linear.w, true)]
    }

    private func near(_ got: ArraySlice<UInt8>, _ want: [UInt8], label: String = "") {
        let arr = Array(got)
        for idx in 0..<4 {
            #expect(
                abs(Int(arr[idx]) - Int(want[idx])) <= 1,
                "\(label): \(arr) != \(want)"
            )
        }
    }

    private func drawRaw(
        renderer: OffscreenGPURenderer,
        frame: RenderFrame,
        linearBytes: Bool = false
    ) throws -> [UInt8] {
        #if canImport(Metal)
        let renderer = renderer.metal
        let pixelFormat: MTLPixelFormat = linearBytes ? .rgba8Unorm : .bgra8Unorm_srgb
        renderer.prepare(frame: frame, viewport: (frame.width, frame.height))
        let w = max(1, frame.width)
        let h = max(1, frame.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        desc.storageMode = .managed
        #else
        desc.storageMode = .shared
        #endif
        guard let target = renderer.device.makeTexture(descriptor: desc),
              let cb = renderer.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "RenderSlice3CacheTests", code: 1)
        }
        renderer.setFormat(pixelFormat)
        renderer.drawRange(frame: frame, into: target, commandBuffer: cb, range: nil)
        #if os(macOS)
        if target.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        #endif
        cb.commit()
        cb.waitUntilCompleted()

        var raw = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(
            &raw,
            bytesPerRow: w * 4,
            from: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0
        )
        if pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb {
            for idx in stride(from: 0, to: raw.count, by: 4) {
                raw.swapAt(idx, idx + 2)
            }
        }
        return raw
        #else
        var rgba = try renderer.renderOffscreen(frame).rgba
        if linearBytes {
            for pixel in stride(from: 0, to: rgba.count, by: 4) {
                for channel in pixel..<(pixel + 3) {
                    let value = RefShader.srgbToLinear(Float(rgba[channel]) / 255)
                    rgba[channel] = UInt8((value * 255).rounded())
                }
            }
        }
        return rgba
        #endif
    }

    private final class CachedPairState<T> {
        let cached: Bool
        var inner: T
        init(cached: Bool, inner: T) {
            self.cached = cached
            self.inner = inner
        }
    }

    @MainActor
    private func sameAsUncached<T>(
        _ initialState: () -> T,
        view: @escaping (CachedPairState<T>, inout Cx<CachedPairState<T>>) -> El<CachedPairState<T>>,
        size: (Int, Int),
        steps: [(name: String, frames: Int, step: (Runtime<CachedPairState<T>>, Double) -> Void)]
    ) throws -> [(String, LayerStats)] {
        let rendererU = try OffscreenGPURenderer()
        let rendererC = try OffscreenGPURenderer()
        let viewport = Vec2(Float(size.0), Float(size.1))
        let rtU = Runtime<CachedPairState<T>>(
            state: CachedPairState(cached: false, inner: initialState()),
            viewport: viewport,
            pixelScale: 1.0,
            view: view
        )
        let rtC = Runtime<CachedPairState<T>>(
            state: CachedPairState(cached: true, inner: initialState()),
            viewport: viewport,
            pixelScale: 1.0,
            view: view
        )
        rtU.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rtC.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rtU.srgbBlend = false
        rtC.srgbBlend = false

        var stats: [(String, LayerStats)] = []
        var now = 0.0
        var lastCachedInstances: [RenderInstance] = []
        let allSteps: [(name: String, frames: Int, step: (Runtime<CachedPairState<T>>, Double) -> Void)] =
            [("rest", 2, { _, _ in })] + steps
        for (name, frames, step) in allSteps {
            step(rtU, now)
            step(rtC, now)
            for f in 0..<frames {
                now += 1.0 / 60.0
                let rfU = try rendererU.frame(rtU, at: now)
                let want = try drawRaw(renderer: rendererU, frame: rfU)

                let rfC = try rendererC.frame(rtC, at: now)
                lastCachedInstances = rfC.instances
                let got = try drawRaw(renderer: rendererC, frame: rfC)

                var maxDiff = 0
                for idx in 0..<min(got.count, want.count) {
                    maxDiff = max(maxDiff, abs(Int(got[idx]) - Int(want[idx])))
                }
                #expect(maxDiff <= 1, "\(name) frame \(f): cached differs from uncached (max_diff=\(maxDiff))")
                stats.append(("\(name)/\(f)", rendererC.layerStats()))
            }
        }
        #expect(
            lastCachedInstances.contains { $0.params.y == KIND_LAYER && $0.params.w == 1.0 },
            "the subtree stays cached"
        )
        return stats
    }

    // 1. #15 (`layer_cache_tests.rs:155`)
    @Test("cache_draws_live_while_subtree_animates_and_recaches_when_settled")
    @MainActor
    func cacheDrawsLiveWhileSubtreeAnimatesAndRecachesWhenSettled() throws {
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<Bool>(state: false, viewport: Vec2(48, 24), pixelScale: 1.0) { moved, _ in
            let x: Float = moved ? 16.0 : 0.0
            return el().size(48, 24).child(
                el().size(40, 20).cache().child(
                    el().key("chip").size(16, 16).absolute(x: x, y: 0)
                        .motion(.default)
                        .bg(Color(r: 1, g: 0, b: 0, a: 1))
                )
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false

        var now = 0.0
        var rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().targets == 1)
        #expect(renderer.layerStats().extraPasses == 1)

        now += 1.0 / 60.0
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 0)

        rt.state = true
        rt.invalidate(at: now)
        _ = rt.renderFrame(at: now)
        for _ in 0..<3 {
            now += 0.05
            rf = rt.renderFrame(at: now)
            #expect(rf.instances.allSatisfy { $0.params.y != KIND_LAYER }, "must draw live while animating")
            _ = try drawRaw(renderer: renderer, frame: rf)
            #expect(renderer.layerStats().extraPasses == 0, "no offscreen pass thrash while animating")
        }

        now += 2.0
        rf = rt.renderFrame(at: now)
        #expect(rf.instances.contains { $0.params.y == KIND_LAYER && $0.params.w == 1.0 }, "re-cached once settled")
        let out = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1, "rasterize once on settle")
        near(out[(8 * 48 + 24) * 4..<(8 * 48 + 25) * 4], srgbBytes(SIMD4<Float>(1, 0, 0, 1)), label: "settled")

        now += 1.0 / 60.0
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 0, "subsequent frame hits settled cache")
    }

    // 2. #18 (`layer_cache_tests.rs:366`)
    @Test("cache_follows_press_paint_that_lands_without_a_view_run")
    @MainActor
    func cacheFollowsPressPaintThatLandsWithoutAViewRun() throws {
        let stats = try sameAsUncached({ () }, view: { s, _ in
            var card: El<CachedPairState<Void>> = el().size(24, 24).child(
                el().size(24, 24)
                    .bg(Color(r: 0.8, g: 0.1, b: 0.2, a: 1))
                    .press(Color(r: 0.1, g: 0.2, b: 0.9, a: 1))
                    .onClick { _ in }
            )
            if s.cached { card = card.cache() }
            return el().size(32, 32).child(card)
        }, size: (32, 32), steps: [
            ("hover", 2, { rt, t in rt.pointerMove(to: Vec2(12, 12), at: t) }),
            ("down", 2, { rt, t in rt.pointerDown(at: Vec2(12, 12), at: t) }),
            ("up", 40, { rt, t in rt.pointerUp(at: Vec2(12, 12), at: t) }),
        ])
        #expect(stats.last?.1.extraPasses == 0, "the released card hits its cache again")
    }

    // 3. #19 (`layer_cache_tests.rs:386`)
    @Test("cache_follows_link_hover_moving_between_links_of_one_text")
    @MainActor
    func cacheFollowsLinkHoverMovingBetweenLinksOfOneText() throws {
        _ = try sameAsUncached({ () }, view: { s, _ in
            let green = LinkPaint().bg(Color(r: 0, g: 1, b: 0, a: 1))
            let label: El<CachedPairState<Void>> = text("MMMM MMMM")
                .font(TextStyle(size: 16, weight: 400))
                .color(.white)
                .link(TextLink(0..<4, id: "a").hover(green))
                .link(TextLink(5..<9, id: "b").hover(green))
                .onLink { _, _ in }
            var card: El<CachedPairState<Void>> = el().size(150, 24).child(label)
            if s.cached { card = card.cache() }
            return el().size(160, 32).child(card)
        }, size: (160, 32), steps: [
            ("first link", 2, { rt, t in rt.pointerMove(to: Vec2(16, 10), at: t) }),
            ("second link", 2, { rt, t in rt.pointerMove(to: Vec2(90, 10), at: t) }),
        ])
    }

    // 4. #20 (`layer_cache_tests.rs:406`)
    @Test("cache_follows_an_outside_hover_group_fading_its_descendants")
    @MainActor
    func cacheFollowsAnOutsideHoverGroupFadingItsDescendants() throws {
        _ = try sameAsUncached({ () }, view: { s, _ in
            var card: El<CachedPairState<Void>> = el().size(24, 24)
                .bg(Color(r: 0, g: 0, b: 1, a: 1))
                .child(el().size(16, 16).bg(.white).groupOpacity(0.2, 1.0))
            if s.cached { card = card.cache() }
            return el().size(64, 32).child(
                row().size(64, 32).hoverGroup().child(card)
            )
        }, size: (64, 32), steps: [
            ("enter", 3, { rt, t in rt.pointerMove(to: Vec2(48, 16), at: t) }),
            ("leave", 12, { rt, t in rt.pointerMove(to: Vec2(200, 200), at: t) }),
        ])
    }

    // 5. #23 (`layer_cache_tests.rs:451`)
    @Test("clicks_land_inside_a_cached_card_after_a_pan")
    @MainActor
    func clicksLandInsideACachedCardAfterAPan() throws {
        typealias S = (count: UInt32, pan: Live<Vec2>)
        let pan = Live<Vec2>(Vec2(0, 0))
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<S>(state: (0, pan), viewport: Vec2(96, 64), pixelScale: 1.0) { s, _ in
            el().size(96, 64).child(
                el().size(96, 64).liveOffset(s.pan.binding).child(
                    el().size(32, 32).cache().bg(.white).child(
                        el().key("button").size(16, 16).bg(Color(r: 1, g: 0, b: 0, a: 1))
                            .onClick { st in st.count += 1 }
                    )
                )
            )
        }
        var now = 0.0
        for _ in 0..<2 {
            now += 1.0 / 60.0
            let rf = rt.renderFrame(at: now)
            _ = try drawRaw(renderer: renderer, frame: rf)
        }
        pan.set(Vec2(50, 30))
        now += 1.0 / 60.0
        let rfPanned = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rfPanned)
        #expect(rfPanned.instances.count == 2, "the panned card is elided to its cached quad")

        for (x, y) in [(Float(8), Float(8)), (Float(58), Float(38))] {
            rt.pointerMove(to: Vec2(x, y), at: now)
            rt.pointerDown(at: Vec2(x, y), at: now)
            rt.pointerUp(at: Vec2(x, y), at: now)
            now += 1.0 / 60.0
            let rf = rt.renderFrame(at: now)
            _ = try drawRaw(renderer: renderer, frame: rf)
        }
        #expect(rt.state.count == 1, "only the click on the button's panned position presses it")
        let b = try #require(rt.elements().first { $0.key == "button" })
        #expect([b.rect[0], b.rect[1]] == [50.0, 30.0], "elements() reports the panned rect")
    }

    // 6. #25 (`layer_cache_tests.rs:508`)
    @Test("cached_card_stays_elided_during_sixty_live_only_wheel_frames")
    @MainActor
    func cachedCardStaysElidedDuringSixtyLiveOnlyWheelFrames() throws {
        typealias S = (count: UInt32, offset: Live<Vec2>)
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<S>(state: (0, Live<Vec2>(Vec2(0, 0))), viewport: Vec2(160, 100), pixelScale: 1.0) { s, _ in
            el().size(160, 100)
                .onWheel { st, e, tx in
                    let p = st.offset.get()
                    st.offset.set(Vec2(p.x + e.dx, p.y + e.dy))
                    tx.liveOnly()
                    return true
                }
                .child(
                    el().size(160, 100).liveOffset(s.offset.binding).child(
                        el().size(32, 32).cache().bg(.white).child(
                            el().key("button").size(16, 16)
                                .bg(Color(r: 1, g: 0, b: 0, a: 1))
                                .onClick { st in st.count += 1 }
                        )
                    )
                )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        rt.checkLiveOnly(false)
        var now = 0.0
        for _ in 0..<3 {
            now += 1.0 / 60.0
            let rf = rt.renderFrame(at: now)
            _ = try drawRaw(renderer: renderer, frame: rf)
        }
        let commits = rt.commitCount
        for frameIdx in 0..<60 {
            rt.wheel(WheelEvent(dx: 1.0, dy: 0.5), at: Vec2(120, 80), now: now)
            now += 1.0 / 60.0
            let rf = rt.renderFrame(at: now)
            #expect(rt.commitCount == commits, "frame \(frameIdx) must not rebuild the view")
            #expect(rf.instances.count == 2, "frame \(frameIdx): child emission stays elided")
            let out = try drawRaw(renderer: renderer, frame: rf)
            if frameIdx == 59 {
                let pOff = (38 * 160 + 68) * 4
                let oOff = (8 * 160 + 8) * 4
                near(out[pOff..<(pOff + 4)], [255, 0, 0, 255], label: "panned-button")
                near(out[oOff..<(oOff + 4)], [0, 0, 0, 0], label: "vacated-origin")
            }
        }
        let b = try #require(rt.elements().first { $0.key == "button" })
        #expect([b.rect[0], b.rect[1]] == [60.0, 30.0])
        rt.pointerDown(at: Vec2(68, 38), at: now)
        rt.pointerUp(at: Vec2(68, 38), at: now)
        now += 1.0 / 60.0
        _ = rt.renderFrame(at: now)
        #expect(rt.state.count == 1, "the click hits the cached child's moved position")
    }

    // 7. #26 (`layer_cache_tests.rs:552`)
    @Test("cache_does_not_hide_a_radius_change_during_scale_settling")
    @MainActor
    func cacheDoesNotHideARadiusChangeDuringScaleSettling() throws {
        typealias S = (rounded: Bool, scale: Live<Float>)
        let scale = Live<Float>(1.0)
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<S>(state: (false, scale), viewport: Vec2(100, 100), pixelScale: 1.0) { s, _ in
            el().size(100, 100).liveScale(s.scale.binding).child(
                el().size(32, 32).cache().child(
                    el().size(32, 32).motion(.none).bg(.white).rounded(s.rounded ? 16 : 0)
                )
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        var rf = rt.renderFrame(at: 0.0)
        _ = try drawRaw(renderer: renderer, frame: rf)

        scale.set(1.01)
        rt.state.rounded = true
        rt.invalidate(at: 1.0 / 60.0)
        rf = rt.renderFrame(at: 1.0 / 60.0)
        let out = try drawRaw(renderer: renderer, frame: rf)
        let cornerAlpha = out[3]
        #expect(cornerAlpha < 32, "the newly rounded corner must not show the stale square (alpha=\(cornerAlpha))")
    }

    // 8. #27 (`layer_cache_tests.rs:579`)
    @Test("slow_pinch_composites_until_the_scale_holds_still")
    @MainActor
    func slowPinchCompositesUntilTheScaleHoldsStill() throws {
        let scale = Live<Float>(1.0)
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<Live<Float>>(state: scale, viewport: Vec2(200, 200), pixelScale: 1.0) { sc, _ in
            el().size(200, 200).p(60).liveScale(sc.binding).child(
                el().size(48, 48).cache().bg(Color(r: 0.2, g: 0.5, b: 0.9, a: 1))
                    .child(el().size(24, 24).bg(.white))
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        var now = 0.0
        var rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1)

        for step in 1...60 {
            scale.set(1.0 + Float(step) * 0.01)
            now += 1.0 / 60.0
            rf = rt.renderFrame(at: now)
            _ = try drawRaw(renderer: renderer, frame: rf)
            #expect(renderer.layerStats().extraPasses == 0, "pinch step \(step) composites the old texture")
        }
        now += 0.15
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1, "one raster once the pinch rests")
    }

    // 9. #28 (`layer_cache_tests.rs:605`)
    @Test("over_budget_cache_falls_back_to_a_viewport_sized_target")
    @MainActor
    func overBudgetCacheFallsBackToAViewportSizedTarget() throws {
        struct S {}
        var want: [UInt8]? = nil
        for budget in [Int(DEFAULT_LAYER_CACHE_BUDGET), 64 * 64 * 8, 0] {
            let renderer = try OffscreenGPURenderer()
            try renderer.setLayerCacheBudget(budget)
            let rt = Runtime<S>(state: S(), viewport: Vec2(32, 32), pixelScale: 1.0) { _, _ in
                el().size(32, 32).child(
                    el().size(300, 300).cache().clipRounded(8).bg(Color(r: 0, g: 0, b: 1, a: 1))
                        .child(el().size(20, 20).bg(.white))
                )
            }
            rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
            rt.srgbBlend = false
            var out: [UInt8] = []
            var now = 0.0
            var allocations: UInt64?
            for _ in 0..<3 {
                now += 1.0 / 60.0
                let rf = rt.renderFrame(at: now)
                out = try drawRaw(renderer: renderer, frame: rf)
                if budget == 0 {
                    let stats = renderer.layerStats()
                    #expect(stats.targets > 0 && stats.bytes > 0, "visible fallback uses a temporary target")
                    #expect(stats.cachedLayers == 0 && stats.cachedBytes == 0)
                    if let allocations {
                        #expect(stats.allocations == allocations, "identical frames reuse the temporary target")
                    } else {
                        allocations = stats.allocations
                    }
                }
            }
            if let expected = want {
                #expect(renderer.layerStats().bytes <= 64 * 64 * 8, "over-budget fallback stays viewport-sized: \(renderer.layerStats())")
                let ok = zip(out, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
                #expect(ok, "fallback draws like the cache")
            } else {
                want = out
            }
            if budget == 0 {
                _ = try drawRaw(renderer: renderer, frame: RenderFrame(width: 32, height: 32))
                let stats = renderer.layerStats()
                #expect(stats.targets == 0 && stats.bytes == 0, "clear-only frame has no active layer targets")
            }
        }
    }

    // 10. #29 (`layer_cache_tests.rs:637`)
    @Test("scale_commits_draw_live_without_repeated_cache_passes")
    @MainActor
    func scaleCommitsDrawLiveWithoutRepeatedCachePasses() throws {
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<Float>(state: 1.0, viewport: Vec2(200, 200), pixelScale: 1.0) { sc, _ in
            el().size(200, 200).scale(sc).scaleMotion(Curve.instant).child(
                el().size(48, 48).cache().bg(.white)
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        var now = 0.0
        var rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)

        for step in 1...30 {
            rt.state = 1.0 + Float(step) * 0.01
            now += 1.0 / 60.0
            rt.invalidate(at: now)
            rf = rt.renderFrame(at: now)
            _ = try drawRaw(renderer: renderer, frame: rf)
            #expect(renderer.layerStats().extraPasses == 0, "scale commit \(step) must not rasterize another cache")
        }
        now += 0.15
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1, "cache once the committed scale settles")
    }

    // 11. #30 (`layer_cache_tests.rs:664`)
    @Test("glyph_atlas_survives_four_hundred_scales_and_renders_fresh_and_cached_text")
    @MainActor
    func glyphAtlasSurvivesFourHundredScalesAndRendersFreshAndCachedText() throws {
        struct State {
            var fontSize: Float
            var banner: String
            var cardText: String
        }
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<State>(
            state: State(
                fontSize: 16.0,
                banner: "The quick brown fox jumps over the lazy dog 0123456789",
                cardText: "CACHED SUBTREE ALPHA"
            ),
            viewport: Vec2(360, 120),
            pixelScale: 1.0
        ) { s, _ in
            col().size(360, 120).gap(8)
                .child(text(s.banner).font(TextStyle(size: s.fontSize, weight: 400)).color(.white))
                .child(
                    el().size(320, 40).cache().child(
                        text(s.cardText).font(TextStyle(size: 16, weight: 500)).color(.white)
                    )
                )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        var now = 0.0
        var rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)

        for i in 0..<400 {
            rt.state.fontSize = 18.0 + Float(i) * 0.45
            rt.invalidate()
            now += 1.0 / 60.0
            _ = rt.renderFrame(at: now)
        }
        let resets = rt.textSystem.glyphAtlas.resets
        #expect(resets >= 2, "400 scales must cycle the glyph atlas (resets=\(resets))")

        rt.state.fontSize = 18.0
        rt.state.banner = "Sphinx of black quartz, judge my vow!"
        rt.state.cardText = "CACHED SUBTREE OMEGA"
        rt.invalidate()
        now += 1.0
        rf = rt.renderFrame(at: now)
        let out = try drawRaw(renderer: renderer, frame: rf)

        let card = try #require(rt.elements().first { $0.text == rt.state.cardText })
        #expect(card.rect[1] >= 0 && card.rect[1] + card.rect[3] <= rt.viewport.y,
                "cached text must be back onscreen after the one-second frame step")
        let glyphs = rf.instances.filter { $0.params.y == KIND_GLYPH }
        func hasInk(_ g: RenderInstance) -> Bool {
            let x0 = min(360, max(0, Int(floorf(g.rect.x))))
            let y0 = min(120, max(0, Int(floorf(g.rect.y))))
            let x1 = min(360, max(0, Int(ceilf(g.rect.x + g.rect.z))))
            let y1 = min(120, max(0, Int(ceilf(g.rect.y + g.rect.w))))
            if y0 < y1 && x0 < x1 {
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let base = (y * 360 + x) * 4
                        if out[base] > 16 || out[base + 1] > 16 || out[base + 2] > 16 {
                            return true
                        }
                    }
                }
            }
            return false
        }
        #if canImport(CoreText)
        let expected = rt.state.banner.filter { !$0.isWhitespace }.count
            + rt.state.cardText.filter { !$0.isWhitespace }.count
        #expect(glyphs.count == expected, "every glyph in both fresh and cached text must be emitted")
        for (idx, glyph) in glyphs.enumerated() {
            #expect(hasInk(glyph), "glyph \(idx) at \(glyph.rect) rendered zero ink pixels")
        }
        #else
        // Native desktop text can emit whitespace quads and split a character at a mask tile boundary.
        var first = 0
        for (string, style) in [(rt.state.banner, TextStyle(size: 18, weight: 400)),
                                (rt.state.cardText, TextStyle(size: 16, weight: 500))] {
            let line = rt.textSystem.shape(text: string, style: style, maxWidth: nil, pixelScale: 1)
            let end = first + line.glyphs.count
            try #require(end <= glyphs.count)
            let visible = Set(zip(line.glyphs, glyphs[first..<end]).compactMap { shaped, drawn in
                hasInk(drawn) ? shaped.utf8Offset : nil
            })
            for (offset, byte) in string.utf8.enumerated() where byte != 0x20 {
                #expect(visible.contains(offset), "character at UTF-8 offset \(offset) in '\(string)' rendered zero ink")
            }
            first = end
        }
        #expect(first == glyphs.count)
        #endif
    }

    #endif

    // 12. #32 (`layer_cache_tests.rs:788`)
    @Test("live_scale_zoom_sweep_buckets_during_motion_and_settles_crisp")
    @MainActor
    func liveScaleZoomSweepBucketsDuringMotionAndSettlesCrisp() throws {
        let zoom = Live<Float>(1.0)
        let rt = Runtime<Live<Float>>(state: zoom, viewport: Vec2(300, 120), pixelScale: 2.0) { z, _ in
            el().size(300, 120).liveScale(z.binding).child(
                text("Hamburgefonstiv").font(TextStyle(size: 14, weight: 400)).color(.white)
            )
        }
        var now = 0.0
        _ = rt.renderFrame(at: now)
        var priorRasterized = rt.textSystem.glyphAtlas.rasterized
        try #require(priorRasterized > 0)
        #if canImport(CoreText)
        #expect(priorRasterized >= 10)
        #endif
        var distinctSizes = 1

        for frameIdx in 1...1200 {
            let u = Float(frameIdx) / 1200.0
            let k = 0.25 * powf(16.0, u)
            zoom.set(k)
            now += 1.0 / 120.0
            _ = rt.renderFrame(at: now)
            let rasterized = rt.textSystem.glyphAtlas.rasterized
            if rasterized > priorRasterized {
                distinctSizes += 1
                priorRasterized = rasterized
            }
        }
        #expect(
            distinctSizes <= 18,
            "10s zoom sweep across [0.25, 4.0] must rasterize at most 17 more bucketed sizes (got \(distinctSizes) including the initial size)"
        )

        zoom.set(1.13)
        now += 1.0 / 120.0
        var rf = rt.renderFrame(at: now)
        #expect(rf.instances.filter { $0.params.y == KIND_GLYPH }.contains { $0.uv.z > 0 }, "filtered while moving")
        for _ in 0..<20 {
            now += 1.0 / 120.0
            rf = rt.renderFrame(at: now)
        }
        #expect(
            rf.instances.filter { $0.params.y == KIND_GLYPH }.allSatisfy { $0.uv.z == 0 },
            "crisp 1:1 glyphs once live_scale settles at 1.13"
        )
        now += 1.0 / 120.0
        _ = rt.renderFrame(at: now)
        #expect(!rt.isAnimating, "nothing keeps animating after live_scale settles")
    }

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    // 13. #33 (`layer_cache_tests.rs:829`)
    @Test("pill_styles_follow_captured_state_through_a_cached_subtree")
    @MainActor
    func pillStylesFollowCapturedStateThroughACachedSubtree() throws {
        let iconA = SVGIcon(viewBox: 8, body: "<rect width=\"8\" height=\"8\"/>")
        let iconB = SVGIcon(viewBox: 8, body: "<circle cx=\"4\" cy=\"4\" r=\"4\"/>")
        final class State {
            var edit: TextEdit
            var swap: Bool
            var calls: Int = 0
            init(edit: TextEdit, swap: Bool) {
                self.edit = edit
                self.swap = swap
            }
        }
        var edit = TextEdit(" ", multiline: false).rich(true)
        edit.setCursor(utf8Offset: 0)
        edit.insertPill(id: "p:1", label: "one")
        edit.insert("  ")
        edit.insertPill(id: "p:2", label: "two")

        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<State>(state: State(edit: edit, swap: false), viewport: Vec2(200, 40), pixelScale: 1.0) { s, _ in
            let swap = s.swap
            let field = textInput(key: "field", \State.edit)
                .font(TextStyle(size: 14, weight: 400))
                .size(200, 30)
                .pillIcon { _ in iconB }
                .pillStyle { id in
                    s.calls += 1
                    let first = (id == "p:1") != swap
                    if first {
                        return PillStyle().bg(Color(r: 1, g: 0, b: 0, a: 1)).icon(iconA)
                    } else {
                        return PillStyle.default.bg(Color(r: 0, g: 0, b: 1, a: 1))
                    }
                }
                .pillColors(Color(r: 0, g: 1, b: 0, a: 1), .white)
                .color(.white)
                .decorations([RichSpan(0..<1)])
            return el().size(200, 40).child(
                el().size(190, 30).child(field).cache()
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false

        var now = 0.0
        func step() throws -> ([UInt8], Int) {
            now += 1.0 / 60.0
            let rf = rt.renderFrame(at: now)
            let out = try drawRaw(renderer: renderer, frame: rf)
            return (out, renderer.layerStats().extraPasses)
        }

        struct MissingChipPixel: Error {}
        func chips(_ out: [UInt8]) throws -> (Int, Int) {
            func first(_ hit: ([UInt8]) -> Bool) -> Int? {
                for x in 0..<200 {
                    for y in 0..<40 {
                        let base = (y * 200 + x) * 4
                        let px = [out[base], out[base + 1], out[base + 2], out[base + 3]]
                        if hit(px) { return x }
                    }
                }
                return nil
            }
            let redHit = first { $0[0] > 120 && $0[2] < 60 }
            let blueHit = first { $0[2] > 120 && $0[0] < 60 }
            guard let red = redHit, let blue = blueHit else {
                Issue.record("missing red/blue pill chip pixels (red=\(String(describing: redHit)), blue=\(String(describing: blueHit)))")
                throw MissingChipPixel()
            }
            return (red, blue)
        }

        func icons() -> [SVGIcon?] {
            rt.flatNodes.first { !$0.el.pillChips.isEmpty }?.el.pillChips.map { $0.icon?.svg } ?? []
        }

        let (out0, passes0) = try step()
        #expect(rt.state.calls == 2, "pillStyle runs once per pill on build despite later builder calls")
        #expect(passes0 == 1, "initial frame rasterizes the cached subtree")
        let (red0, blue0) = try chips(out0)
        #expect(red0 < blue0, "p:1 draws red then p:2 blue: \(red0) \(blue0)")
        #expect(try step().1 == 0, "steady frame hits the cached layer")
        rt.invalidate(at: now)
        #expect(try step().1 == 0, "rebuilding with unchanged pill styles keeps the cached layer")
        #expect(icons() == [iconA, iconB])

        rt.state.calls = 0
        rt.state.swap = true
        rt.invalidate(at: now)
        let (out1, passes1) = try step()
        #expect(rt.state.calls == 2, "pillStyle runs once per pill when rebuilt")
        #expect(passes1 == 1, "changed pill styles invalidate the cached layer")
        let (red1, blue1) = try chips(out1)
        #expect(blue1 < red1, "after the captured state flips the cached chips restyle: \(red1) \(blue1)")
        #expect(icons() == [iconB, iconA])
        #expect(try step().1 == 0, "next frame hits the newly cached layer")
    }

    // 14. #13 (`layer_cache_tests.rs:5`)
    @Test("cache_matches_uncached_at_rest_and_skips_rerasterize_on_ancestor_live_offset")
    @MainActor
    func cacheMatchesUncachedAtRestAndSkipsRerasterizeOnAncestorLiveOffset() throws {
        typealias State = (cached: Bool, offset: Live<Vec2>)
        func crispView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
            var card: El<State> = col()
                .size(40, 28)
                .p(4)
                .gap(2)
                .bg(Color(r: 0, g: 0, b: 1, a: 1))
                .child(el().size(24, 8).bg(Color(r: 1, g: 0, b: 0, a: 1)))
                .child(el().size(16, 8).bg(.white))
            if s.cached { card = card.cache() }
            return el().size(64, 48).p(6).liveOffset(s.offset.binding).child(card)
        }
        func richView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
            var card: El<State> = col()
                .size(40, 28)
                .p(4)
                .gap(2)
                .bg(Color(r: 0.2, g: 0.35, b: 0.6, a: 1))
                .rounded(6)
                .border(1, .white)
                .child(text("Cached").color(.white))
                .child(el().size(24, 8).bg(Color(r: 0.9, g: 0.3, b: 0.2, a: 1)).rounded(3))
            if s.cached { card = card.cache() }
            return el().size(64, 48).p(6).liveOffset(s.offset.binding).child(card)
        }

        let renU = try OffscreenGPURenderer()
        let rtU = Runtime<State>(state: (false, Live<Vec2>(.zero)), viewport: Vec2(64, 48), pixelScale: 1.0, view: crispView)
        rtU.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rtU.srgbBlend = false
        let rfU = rtU.renderFrame(at: 0.0)
        let pxU = try drawRaw(renderer: renU, frame: rfU)

        let renC = try OffscreenGPURenderer()
        let rtC = Runtime<State>(state: (true, Live<Vec2>(.zero)), viewport: Vec2(64, 48), pixelScale: 1.0, view: crispView)
        rtC.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rtC.srgbBlend = false
        let rfC = rtC.renderFrame(at: 0.0)
        let pxC = try drawRaw(renderer: renC, frame: rfC)
        #expect(pxC == pxU, "cached vs uncached must be pixel-for-pixel identical at rest")

        let offUncached = Live<Vec2>(.zero)
        let rtUncached = Runtime<State>(state: (false, offUncached), viewport: Vec2(64, 48), pixelScale: 1.0, view: richView)
        rtUncached.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rtUncached.srgbBlend = false
        let renUncached = try OffscreenGPURenderer()
        let rfUncached0 = rtUncached.renderFrame(at: 0.0)
        let pxUncached = try drawRaw(renderer: renUncached, frame: rfUncached0)

        let offCached = Live<Vec2>(.zero)
        let rtCached = Runtime<State>(state: (true, offCached), viewport: Vec2(64, 48), pixelScale: 1.0, view: richView)
        rtCached.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rtCached.srgbBlend = false
        let renCached = try OffscreenGPURenderer()
        let rfCached0 = rtCached.renderFrame(at: 0.0)
        let pxCached = try drawRaw(renderer: renCached, frame: rfCached0)
        #expect(renCached.layerStats().targets == 1)
        #expect(renCached.layerStats().extraPasses == 1, "initial frame rasterizes the cache")
        let restMaxDiff = zip(pxCached, pxUncached).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(restMaxDiff <= 1, "cached vs uncached at rest maxDiff=\(restMaxDiff)")
        #expect(rtCached.elements().count == rtUncached.elements().count, "elements() unchanged")

        var now = 0.0
        for delta in [Vec2(4, 2), Vec2(10, 6), Vec2(3, 8), Vec2(0, 0)] {
            now += 1.0 / 60.0
            offUncached.set(delta)
            let rfWant = rtUncached.renderFrame(at: now)
            let want = try drawRaw(renderer: renUncached, frame: rfWant)

            offCached.set(delta)
            let rfGot = rtCached.renderFrame(at: now)
            #expect(rfGot.instances.count == 2, "cached subtree elides to [KIND_LAYER, KIND_LAYER_END]")
            let got = try drawRaw(renderer: renCached, frame: rfGot)
            #expect(renCached.layerStats().extraPasses == 0, "ancestor live_offset must not re-rasterize")
            #expect(renCached.layerStats().allocations == 1)
            let maxDiff = zip(got, want).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(maxDiff <= 1, "panned cached output must match uncached at \(delta) (maxDiff=\(maxDiff))")
            if delta == .zero {
                #expect(got == pxCached, "returning to origin is bit-for-bit identical")
            }
        }
    }

    // 15. #14 (`layer_cache_tests.rs:95`)
    @Test("cache_invalidates_on_state_and_hover_changes")
    @MainActor
    func cacheInvalidatesOnStateAndHoverChanges() throws {
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<Bool>(state: false, viewport: Vec2(32, 32), pixelScale: 1.0) { active, _ in
            let fill = active ? Color(r: 0.1, g: 0.8, b: 0.2, a: 1) : Color(r: 0.8, g: 0.1, b: 0.2, a: 1)
            return el().size(32, 32).child(
                el().size(24, 24).cache().child(
                    el().key("btn")
                        .size(24, 24)
                        .bg(fill)
                        .hover(Color(r: 0.1, g: 0.2, b: 0.9, a: 1))
                        .onClick { st in st = !st }
                )
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        let pOff = (12 * 32 + 12) * 4

        var now = 0.0
        var rf = rt.renderFrame(at: now)
        var out = try drawRaw(renderer: renderer, frame: rf, linearBytes: true)
        #expect(renderer.layerStats().extraPasses == 1)
        near(out[pOff..<(pOff + 4)], [204, 26, 51, 255], label: "rest")

        now += 1.0 / 60.0
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf, linearBytes: true)
        #expect(renderer.layerStats().extraPasses == 0)

        rt.state = true
        rt.invalidate(at: now)
        now += 1.0
        rf = rt.renderFrame(at: now)
        out = try drawRaw(renderer: renderer, frame: rf, linearBytes: true)
        #expect(renderer.layerStats().extraPasses == 1, "state change must invalidate cache")
        near(out[pOff..<(pOff + 4)], [26, 204, 51, 255], label: "state")

        now += 1.0 / 60.0
        rt.pointerMove(to: Vec2(12, 12), at: now)
        rf = rt.renderFrame(at: now)
        out = try drawRaw(renderer: renderer, frame: rf, linearBytes: true)
        #expect(renderer.layerStats().extraPasses == 1, "hover change must invalidate cache")
        near(out[pOff..<(pOff + 4)], [26, 51, 230, 255], label: "hover")

        now += 1.0 / 60.0
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf, linearBytes: true)
        #expect(renderer.layerStats().extraPasses == 0, "settled hover must hit cache")
    }

    // 16. #16 (`layer_cache_tests.rs:209`)
    @Test("cache_rerasterizes_at_new_resolution_after_ancestor_scale_settles")
    @MainActor
    func cacheRerasterizesAtNewResolutionAfterAncestorScaleSettles() throws {
        let scale = Live<Float>(1.0)
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<Live<Float>>(state: scale, viewport: Vec2(200, 200), pixelScale: 1.0) { sc, _ in
            el().size(200, 200).p(60).liveScale(sc.binding).child(
                el().size(48, 48).cache().bg(Color(r: 0.2, g: 0.5, b: 0.9, a: 1))
                    .child(el().size(24, 24).bg(.white))
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false

        var now = 0.0
        var rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1)
        let originalBytes = renderer.layerStats().bytes
        #expect(originalBytes > 0)
        #if canImport(Metal)
        #expect(originalBytes == 64 * 64 * 8)
        #endif

        scale.set(2.0)
        now += 0.016
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 0, "composite existing texture during scale gesture")
        #expect(renderer.layerStats().bytes == originalBytes, "still 1x texture before settle")

        now += 0.15
        rf = rt.renderFrame(at: now)
        let out = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1, "re-rasterize at new resolution once settled")
        #expect(renderer.layerStats().bytes > originalBytes, "settled scale needs a higher-resolution texture")
        #if canImport(Metal)
        #expect(renderer.layerStats().bytes == 128 * 128 * 8, "upgraded to 2x texture bucket")
        #endif
        #expect(out[(100 * 200 + 100) * 4 + 3] == 255)

        now += 0.016
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 0)
    }

    // 17. #17 (`layer_cache_tests.rs:256`)
    @Test("cache_lru_eviction_under_small_budget_evicts_oldest_and_recaches_cleanly")
    @MainActor
    func cacheLruEvictionUnderSmallBudgetEvictsOldestAndRecachesCleanly() throws {
        let offset = Live<Vec2>(.zero)
        let renderer = try OffscreenGPURenderer()
        func card(_ key: String, y: Float, _ color: Color) -> El<Live<Vec2>> {
            el().key(key).size(24, 24).absolute(x: 4, y: y).cache().bg(color)
                .child(el().size(10, 10).bg(.white))
        }
        let rt = Runtime<Live<Vec2>>(state: offset, viewport: Vec2(32, 32), pixelScale: 1.0) { off, _ in
            el().size(32, 32).child(
                el().size(32, 300).liveOffset(off.binding)
                    .child(card("a", y: 0, Color(r: 1, g: 0, b: 0, a: 1)))
                    .child(card("b", y: 100, Color(r: 0, g: 1, b: 0, a: 1)))
                    .child(card("c", y: 200, Color(r: 0, g: 0, b: 1, a: 1)))
            )
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        let pOff = (16 * 32 + 16) * 4

        var now = 0.0
        var rf = rt.renderFrame(at: now)
        var out = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1)
        let oneBucket = try #require(Int(exactly: renderer.layerStats().bytes))
        try #require(oneBucket > 0)
        try renderer.setLayerCacheBudget(oneBucket * 2)
        #if canImport(Metal)
        #expect(oneBucket == 64 * 64 * 8)
        #expect(renderer.metal.layersPool.cacheBudgetBytes == oneBucket * 2)
        #endif
        near(out[pOff..<(pOff + 4)], [255, 0, 0, 255], label: "card-a")

        offset.set(Vec2(0, -100))
        now += 0.016
        rf = rt.renderFrame(at: now)
        out = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1)
        #expect(renderer.layerStats().targets == 2)
        #expect(renderer.layerStats().bytes <= oneBucket * 2)
        near(out[pOff..<(pOff + 4)], [0, 255, 0, 255], label: "card-b")

        offset.set(.zero)
        now += 0.016
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 0, "A was retained in budget")

        offset.set(Vec2(0, -200))
        now += 0.016
        rf = rt.renderFrame(at: now)
        out = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1, "C rasterizes and evicts LRU B")
        #expect(renderer.layerStats().targets == 2)
        #expect(renderer.layerStats().bytes <= oneBucket * 2)
        near(out[pOff..<(pOff + 4)], [0, 0, 255, 255], label: "card-c")

        offset.set(.zero)
        now += 0.016
        rf = rt.renderFrame(at: now)
        _ = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 0, "MRU card A stayed resident")

        offset.set(Vec2(0, -100))
        now += 0.016
        rf = rt.renderFrame(at: now)
        out = try drawRaw(renderer: renderer, frame: rf)
        #expect(renderer.layerStats().extraPasses == 1, "evicted card B re-caches cleanly")
        near(out[pOff..<(pOff + 4)], [0, 255, 0, 255], label: "card-b-recached")

        let beforeEviction = renderer.layerStats()
        #expect(beforeEviction.hits > 0)
        #expect(beforeEviction.misses > 0)
        #expect(beforeEviction.evictions > 0)
        try renderer.setLayerCacheBudget(0)
        #expect(rt.residentCacheTracker.isEmpty)
        now += 0.016
        rf = rt.renderFrame(at: now)
        #expect(rf.instances.contains { $0.params.y == KIND_RECT }, "eviction makes the runtime emit the card again")
        out = try drawRaw(renderer: renderer, frame: rf)
        near(out[pOff..<(pOff + 4)], [0, 255, 0, 255], label: "card-b-without-cache")
        #expect(renderer.layerStats().cachedBytes == 0)
    }

    // 18. #21 (`layer_cache_tests.rs:421`)
    @Test("cache_redraws_a_same_length_text_change")
    @MainActor
    func cacheRedrawsASameLengthTextChange() throws {
        let stats = try sameAsUncached({ false }, view: { state, _ in
            var card: El<CachedPairState<Bool>> = el().size(60, 24).child(text(state.inner ? "BBBB" : "AAAA").color(.white))
            if state.cached { card = card.cache() }
            return el().size(64, 32).child(card)
        }, size: (64, 32), steps: [
            ("swap", 40, { rt, t in
                rt.state.inner = true
                rt.invalidate(at: t)
            }),
        ])
        let passes = stats.map { $0.1.extraPasses }
        #expect(Array(passes.prefix(2)) == [1, 0])
        #expect(passes.dropFirst(2).reduce(0, +) == 1, "the new text rasterizes once: \(passes)")
        #expect(passes.last == 0)
    }

    // 19. #22 (`layer_cache_tests.rs:437`)
    @Test("cache_invalidates_the_cached_roots_blur")
    @MainActor
    func cacheInvalidatesTheCachedRootsBlur() throws {
        _ = try sameAsUncached({ false }, view: { state, _ in
            var card: El<CachedPairState<Bool>> = el().size(24, 24).absolute(x: 16, y: 16)
                .blur(state.inner ? 3.0 : 0.0)
                .blurMotion(.none)
                .child(el().size(16, 16).bg(.white))
            if state.cached { card = card.cache() }
            return el().size(64, 64).child(card)
        }, size: (64, 64), steps: [
            ("blur", 3, { rt, t in
                rt.state.inner = true
                rt.invalidate(at: t)
            }),
        ])
    }

    // 20. #24 (`layer_cache_tests.rs:488`)
    @Test("cache_updates_same_size_image_pixels_after_the_first_raster")
    @MainActor
    func cacheUpdatesSameSizeImagePixelsAfterTheFirstRaster() throws {
        let renderer = try OffscreenGPURenderer()
        let image = Pixels()
        let rt = Runtime<Pixels>(state: image, viewport: Vec2(32, 32), pixelScale: 1.0) { img, _ in
            el().size(32, 32).child(el().size(24, 24).cache().pixels(img))
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        var now = 0.0
        for color: [UInt8] in [[255, 0, 0, 255], [0, 255, 0, 255]] {
            image.set(width: 2, height: 2, rgba: color + color + color + color)
            now += 1.0 / 60.0
            let rf = rt.renderFrame(at: now)
            let out = try drawRaw(renderer: renderer, frame: rf)
            let pOff = (12 * 32 + 12) * 4
            #expect(Array(out[pOff..<(pOff + 4)]) == color, "same-size image publication must change the output")
        }
    }

    // 21. #31 (`layer_cache_tests.rs:741`)
    @Test("single_frame_spanning_multiple_glyph_atlas_pages_draws_all_pages")
    @MainActor
    func singleFrameSpanningMultipleGlyphAtlasPagesDrawsAllPages() throws {
        let renderer = try OffscreenGPURenderer()
        let rt = Runtime<Void>(state: (), viewport: Vec2(512, 512), pixelScale: 1.0) { _, _ in
            var root: El<Void> = el().size(512, 512)
            for i in 0..<24 {
                root = root.child(
                    text("ABCDEFGHIJKLMN")
                        .absolute(x: 4, y: Float(i * 8))
                        .font(TextStyle(size: 150 + Float(i) * 2, weight: 700))
                        .color(.white)
                )
            }
            return root
        }
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        rt.srgbBlend = false
        let rf = rt.renderFrame(at: 0.0)
        let pageCount = rt.textSystem.glyphAtlas.pageCount
        #expect(rf.glyphPages.count == pageCount)
        #if os(macOS)
        // At these sizes every ink reaches the same dilation cap. Rust allocates each
        // glyph once, including under the default CoreGraphics smoothing mode.
        #expect(rt.textSystem.glyphAtlas.rasterized == 24 * 14)
        #expect(pageCount == 2)
        #endif
        #expect(pageCount >= 2, "single frame must allocate >= 2 pages (got \(pageCount))")
        #expect(rt.textSystem.glyphAtlas.resets == 0, "single frame must not reset a live page mid-frame")
        #expect(rf.instances.contains { $0.params.y == KIND_GLYPH && $0.params.z == 0 }, "has page 0 glyphs")
        #expect(rf.instances.contains { $0.params.y == KIND_GLYPH && $0.params.z >= 1 }, "has page 1+ glyphs")

        let out = try drawRaw(renderer: renderer, frame: rf)
        for page in 0..<2 {
            var found: RenderInstance? = nil
            for inst in rf.instances {
                let inViewport = inst.rect.x >= 0
                    && inst.rect.y >= 0
                    && (inst.rect.x + inst.rect.z) <= 512
                    && (inst.rect.y + inst.rect.w) <= 512
                if inst.params.y == KIND_GLYPH && inst.params.z == Float(page) && inViewport {
                    found = inst
                    break
                }
            }
            guard let g = found else {
                Issue.record("expected in-viewport glyph on page \(page)")
                return
            }
            let x0 = Int(floorf(g.rect.x))
            let y0 = Int(floorf(g.rect.y))
            let x1 = Int(ceilf(g.rect.x + g.rect.z))
            let y1 = Int(ceilf(g.rect.y + g.rect.w))
            var lit = 0
            for y in y0..<y1 {
                for x in x0..<x1 where out[(y * 512 + x) * 4] > 16 {
                    lit += 1
                }
            }
            let rDesc = "\(g.rect)"
            #expect(lit > 0, "glyph on page \(page) at \(rDesc) must render visible pixels")
        }
    }
    #endif
}
