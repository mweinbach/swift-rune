import Foundation
import Testing
@testable import Rune

#if canImport(Metal)
import Metal

@Suite("Layer Rebind, Pooling & Show Parity")
struct LayerRebindAndShowTests {
    private func solidRect(_ bounds: SIMD4<Float>, fill: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) -> RenderInstance {
        RenderInstance(
            rect: bounds,
            radii: .zero,
            fill: fill,
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
    }

    private func cachedCard(bounds: SIMD4<Float>, nodeId: UInt64 = 7, signature: UInt64 = 1) -> [RenderInstance] {
        var cache = RenderInstance.beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec())
        cache.params.w = 1.0
        cache.radii = packU64ToFloat4(nodeId)
        cache.uv = packU64ToFloat4(signature)
        let inner = SIMD4<Float>(bounds.x + 4, bounds.y + 2, bounds.z - 8, bounds.w - 4)
        return [
            cache,
            .beginLayer(bounds: inner, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)),
            solidRect(inner),
            solidRect(SIMD4<Float>(inner.x + 4, inner.y, inner.z - 8, inner.w)),
            .endLayer(),
            .endLayer(),
        ]
    }

    /// Reuses parked `LayersPool` spare targets cleanly across texture/atlas growth (`layer_rebind_tests.rs`).
    @Test("a_parked_target_rebinds_and_reuses_spares_without_extra_allocations")
    func parkedTargetReusesSparesAcrossAtlasGrowth() throws {
        let renderer = try MetalRenderer()
        let pool = LayersPool()
        let device = renderer.device

        // Frame 1: acquire 4 layer targets
        pool.beginFrame()
        for _ in 0..<4 {
            let tex = pool.acquireTarget(device: device, width: 32, height: 16, format: .rgba16Float)
            #expect(tex != nil)
        }
        pool.endFrame()
        let allocsAfterFirst = pool.stats().allocations
        #expect(allocsAfterFirst == 4)
        #expect(pool.stats().targets == 4)

        // Frame 2: layerless frame leaves all 4 targets parked in spares
        pool.beginFrame()
        pool.endFrame()
        #expect(pool.stats().allocations == allocsAfterFirst)

        // Frame 3: re-acquire one target from spares -> zero new allocations
        pool.beginFrame()
        let reused = pool.acquireTarget(device: device, width: 32, height: 16, format: .rgba16Float)
        #expect(reused != nil)
        pool.endFrame()
        #expect(pool.stats().allocations == allocsAfterFirst)

        // Render with MetalRenderer across changing glyph/image atlases reusing layer targets
        let group = [
            RenderInstance.beginLayer(bounds: SIMD4<Float>(8, 8, 32, 16), clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)),
            solidRect(SIMD4<Float>(8, 8, 32, 16)),
            RenderInstance.endLayer(),
        ]
        let frame1 = RenderFrame(
            width: 64,
            height: 64,
            glyphs: R8Atlas(width: 16, height: 16, texels: [UInt8](repeating: 0, count: 256)),
            glyphGeneration: 1,
            instances: group
        )
        _ = try renderer.renderOffscreen(frame1)
        let rendererAllocs = renderer.layerStats().allocations

        // Layerless frame parks target; atlas grows; next frame with layer takes parked target cleanly
        let frame2 = RenderFrame(
            width: 64,
            height: 64,
            glyphs: R8Atlas(width: 64, height: 64, texels: [UInt8](repeating: 128, count: 4096)),
            glyphGeneration: 2,
            instances: []
        )
        _ = try renderer.renderOffscreen(frame2)

        let frame3 = RenderFrame(
            width: 64,
            height: 64,
            glyphs: R8Atlas(width: 64, height: 64, texels: [UInt8](repeating: 128, count: 4096)),
            glyphGeneration: 2,
            instances: group
        )
        let out3 = try renderer.renderOffscreen(frame3)
        #expect(renderer.layerStats().allocations == rendererAllocs)
        #expect(out3.rgba[(16 * 64 + 24) * 4 + 3] > 100)
    }

    /// `a_cache_hit_composites_with_its_layer_turn` (`layer_show_tests.rs:24-54`).
    @Test("a_cache_hit_composites_with_its_layer_turn")
    func cacheHitCompositesWithLayerTurn() throws {
        let renderer = try MetalRenderer()
        let bounds = SIMD4<Float>(16, 22, 32, 12)
        func turned(_ angle: Float?) -> [RenderInstance] {
            var cache = RenderInstance.beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec())
            if let angle {
                cache = cache.turned(angle: angle, pivot: SIMD2<Float>(32, 28))
            }
            cache.params.w = 1.0
            cache.radii = packU64ToFloat4(31)
            cache.uv = packU64ToFloat4(1)
            return [
                cache,
                solidRect(SIMD4<Float>(bounds.x + 2, bounds.y + 2, 8, 6)),
                .endLayer(),
            ]
        }

        let instances = turned(0.6)
        let miss = try renderer.renderOffscreen(RenderFrame(width: 64, height: 64, clearColor: .zero, instances: instances))
        #expect(renderer.layerStats().misses >= 1)

        let hit = try renderer.renderOffscreen(RenderFrame(width: 64, height: 64, clearColor: .zero, instances: instances))
        #expect(renderer.layerStats().hits >= 1)
        #expect(hit.rgba == miss.rgba, "a cache hit must composite the turned quad identical to the miss")

        // Upright version draws at different pixels
        let upright = turned(nil)
        _ = try renderer.renderOffscreen(RenderFrame(width: 64, height: 64, clearColor: .zero, instances: upright))
        let uprightOut = try renderer.renderOffscreen(RenderFrame(width: 64, height: 64, clearColor: .zero, instances: upright))
        #expect(uprightOut.rgba != hit.rgba)
    }

    /// `a_layer_inside_a_cache_that_misses_its_budget_still_draws` (`layer_show_tests.rs:59-79`).
    @Test("a_layer_inside_a_cache_that_misses_its_budget_still_draws")
    func layerInsideBudgetMissedCacheStillDraws() throws {
        let renderer = try MetalRenderer()
        let instances = cachedCard(bounds: SIMD4<Float>(4, 2, 24, 12))
        let tracker = ResidentLayerTracker()
        let at = (8 * 32 + 16) * 4

        let f1 = try renderer.renderOffscreen(
            RenderFrame(width: 32, height: 16, clearColor: .zero, instances: instances, residentTracker: tracker)
        )
        #expect(abs(Int(f1.rgba[at + 3]) - 128) <= 2)
        #expect(tracker.isResident(nodeId: 7, signature: 1))

        // Hit frame
        let f2 = try renderer.renderOffscreen(
            RenderFrame(width: 32, height: 16, clearColor: .zero, instances: instances, residentTracker: tracker)
        )
        #expect(renderer.layerStats().hits >= 1)
        #expect(abs(Int(f2.rgba[at + 3]) - 128) <= 2)

        // Drop cache budget to 1 byte so retained entry is evicted; frame still renders nested half-opacity group cleanly
        renderer.setLayerCacheBudget(1)
        #expect(!tracker.isResident(nodeId: 7, signature: 1))

        let f3 = try renderer.renderOffscreen(
            RenderFrame(width: 32, height: 16, clearColor: .zero, instances: instances, residentTracker: tracker)
        )
        #expect(abs(Int(f3.rgba[at + 3]) - 128) <= 2)
    }
}
#endif
