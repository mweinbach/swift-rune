#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import CRuneGL
import RuneRef
import Testing
@testable import Rune

/// Port of render/layers/plan_frame_tests.rs for the sequential GL compositor.
@MainActor
@Suite("Portable GL layer planning")
struct PortableGLPlannerTests {
    private func group(_ bounds: SIMD4<Float>, opacity: Float = 0.5,
                       key: UInt64? = nil, blur: Float = 0) -> [RenderInstance] {
        var scope = RenderInstance.beginLayer(bounds: bounds, clip: NO_CLIP,
                                              spec: LayerSpec(opacity: opacity, blur: blur))
        if let key {
            scope.params.w = 1
            scope.radii = packU64ToFloat4(key)
            scope.uv = packU64ToFloat4(1)
        }
        return [scope, RenderInstance(rect: bounds, fill: SIMD4(1, 1, 1, 1), clip: NO_CLIP), .endLayer()]
    }

    @Test("Returning to twelve or thirteen cached rows reuses every texture and draws the correct rows")
    func alternatingVisibleRows() throws {
        try withTestGLTarget { renderer, capture in
            let rows = (0..<160).flatMap { row in
                group(SIMD4(0, Float(row * 16), 64, 16), opacity: 1, key: UInt64(row))
            }
            let w = 64, h = 160 * 16
            func visible(_ count: Int) throws -> Frame {
                let frame = RenderFrame(width: w, height: h, clearColor: .zero,
                                        instances: Array(rows.prefix(count * 3)))
                return try capture(w, h) { try renderer.draw(frame) }
            }
            let all = try visible(160)
            #expect(all.pixel(x: 2, y: h - 1).w == 255)
            let warm = renderer.layerStats()
            #expect(warm.extraPasses == 160 && warm.cachedLayers == 160)
            for count in [13, 12, 13, 12, 13, 12, 13, 12] {
                let hits = renderer.layerStats().hits
                let pixels = try visible(count)
                let stats = renderer.layerStats()
                #expect(stats.hits == hits + UInt64(count))
                #expect(stats.extraPasses == 0 && stats.allocations == warm.allocations)
                #expect(pixels.pixel(x: 32, y: count * 16 - 1).w == 255)
                #expect(pixels.pixel(x: 32, y: count * 16).w == 0)
            }
        }
    }

    @Test("A menu can open and close after a thousand-layer burst without allocating")
    func menuAfterBurst() throws {
        let burst = (0..<1024).flatMap { (index: Int) -> [RenderInstance] in
            let x = Float(index % 32) * 8, y = Float(index / 32) * 8
            return group(SIMD4(x, y, 8, 8))
        }
        try withTestGLTarget { renderer, capture in
            func render(_ instances: [RenderInstance]) throws -> Frame {
                let frame = RenderFrame(width: 256, height: 256, clearColor: .zero, instances: instances)
                return try capture(256, 256) { try renderer.draw(frame) }
            }
            let first = try render(burst)
            let warm = renderer.layerStats()
            #expect(warm.extraPasses == 1024)
            #expect(rune_gl_layer_storage(renderer.handle).plan_capacity >= 1024)
            #expect(abs(Int(first.pixel(x: 250, y: 250).w) - 128) <= 1)
            for _ in 0..<4 {
                let empty = try render([])
                #expect(renderer.layerStats().extraPasses == 0 && renderer.layerStats().targets == 0)
                #expect(empty.pixel(x: 2, y: 2).w == 0)
                #expect(rune_gl_layer_storage(renderer.handle).plan_capacity <= 64)
                let secondEmpty = try render([])
                #expect(secondEmpty.rgba == empty.rgba)
                let one = try render(Array(burst.prefix(3)))
                #expect(renderer.layerStats().allocations == warm.allocations)
                #expect(abs(Int(one.pixel(x: 2, y: 2).w) - 128) <= 1)
                #expect(one.pixel(x: 250, y: 250).w == 0)
            }
        }
    }

    @Test("Rotating a cached quad and refusing an enclosing cache preserve the layer pixels")
    func cachedTransformAndBudget() throws {
        try withTestGLTarget { renderer, capture in
            let bounds = SIMD4<Float>(16, 22, 32, 12)
            func draw(_ instances: [RenderInstance]) throws -> Frame {
                let frame = RenderFrame(width: 64, height: 64, clearColor: .zero, instances: instances)
                return try capture(64, 64) { try renderer.draw(frame) }
            }
            var card = group(bounds, opacity: 1, key: 31)
            card[1] = RenderInstance(rect: SIMD4(18, 24, 8, 6), fill: SIMD4(1, 1, 1, 1), clip: NO_CLIP)
            let upright = try draw(card)
            #expect(upright.pixel(x: 20, y: 26).w == 255)
            card[0] = card[0].turned(angle: 0.6, pivot: SIMD2(32, 28))
            let hits = renderer.layerStats().hits
            let rotated = try draw(card)
            #expect(renderer.layerStats().hits == hits + 1)
            #expect(rotated.rgba != upright.rgba)
            renderer.setLayerCacheBudget(0)
            let uncached = try draw(card)
            #expect(rotated.rgba == uncached.rgba)
            // Two overlapping solid children in a half-opaque group must still
            // composite only once after their enclosing cache is refused.
            var refused = group(bounds, opacity: 1, key: 7)
            var children = group(SIMD4(18, 24, 24, 8))
            children.insert(children[1], at: 2)
            refused.replaceSubrange(1...1, with: children)
            let pixels = try draw(refused)
            #expect(renderer.layerStats().cachedLayers == 0)
            #expect(abs(Int(pixels.pixel(x: 32, y: 28).w) - 128) <= 1)
        }
    }

    @Test("A refused blur shader draws unfiltered layers and supports subsequent frames")
    func refusedBlur() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        var compiles = 0
        let renderer = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES) { name in
            if name == "frame_blur.frag" {
                compiles += 1
                return "invalid blur shader"
            }
            return try PortableGLRenderer.bundledShader(name)
        }
        defer { renderer.close() }
        for sigma: Float in [4, 0, 4] {
            let draws = group(SIMD4(4, 4, 12, 8), opacity: 1, blur: sigma)
            let input = RenderFrame(width: 24, height: 16, clearColor: .zero, instances: draws)
            let pixels = try context.withFramebuffer(width: 24, height: 16) { try renderer.draw(input) }
            #expect(pixels.pixel(x: 4, y: 8) == SIMD4(repeating: 255))
            #expect(pixels.pixel(x: 3, y: 8) == .zero)
        }
        #expect(compiles == 1)
    }

    @Test("A blurred 2000-point layer releases its scratch when two sharp siblings replace it")
    func largeBlurThenSiblings() throws {
        try withTestGLTarget { renderer, capture in
            let first = SIMD4<Float>(4, 4, 2000, 2000)
            let second = SIMD4<Float>(8, 8, 2000, 2000)
            func render(_ draws: [RenderInstance]) throws -> Frame {
                let frame = RenderFrame(width: 2048, height: 2048, clearColor: .zero, instances: draws)
                return try capture(2048, 2048) { try renderer.draw(frame) }
            }
            let blurred = try render(group(first, blur: 1))
            let live = rune_gl_layer_storage(renderer.handle)
            #expect(live.filter_bytes > 0 && live.texture_bytes <= 64 << 20)
            #expect(abs(Int(blurred.pixel(x: 24, y: 24).w) - 128) <= 1)
            let fringe = blurred.pixel(x: 3, y: 900).w
            #expect(fringe > 0 && fringe < 128)
            let sharp = try render(group(first) + group(second))
            let rest = rune_gl_layer_storage(renderer.handle)
            #expect(rest.filter_bytes == 0 && rest.texture_bytes <= 64 << 20)
            #expect(renderer.layerStats().extraPasses == 2)
            #expect(sharp.pixel(x: 3, y: 900).w == 0)
            #expect(abs(Int(sharp.pixel(x: 24, y: 24).w) - 191) <= 1)
        }
    }

    @Test("Sixty scale and opacity frames reuse a size bucket and preserve premultiplied coverage")
    func liveScaleAndFade() throws {
        let scale = Live<Float>(0.9), opacity = Live<Float>(0.1)
        let runtime = Runtime<Void>(state: (), viewport: Vec2(256, 256), pixelScale: 1) { _, _ in
            el().size(256, 256).child(
                el().size(180, 180).liveScale(scale.binding).liveOpacity(opacity.binding)
                    .child(el().size(180, 180).bg(.white))
                    .child(el().size(90, 90).bg(.white)))
        }
        runtime.clearColor = .transparent
        try withTestGLTarget { renderer, capture in
            var allocations: UInt64 = 0
            var firstEdge = 0
            for tick in 0...60 {
                let t = Float(tick) / 60
                scale.set(0.9 + 0.1 * t)
                opacity.set(0.1 + 0.8 * t)
                let frame = renderer.frame(runtime, at: Double(tick) / 60)
                let pixels = try capture(256, 256) { try renderer.draw(frame) }
                let stats = renderer.layerStats()
                if tick == 0 { allocations = stats.allocations }
                #expect(allocations == 1 && stats.allocations == allocations, "tick \(tick): \(stats)")
                #expect(abs(Int(pixels.pixel(x: 90, y: 90).w) - Int(((0.1 + 0.8 * t) * 255).rounded())) <= 1)
                if tick == 0 || tick == 60 {
                    let edge = try #require((0..<256).last { pixels.pixel(x: $0, y: 90).w > 10 })
                    if tick == 0 { firstEdge = edge } else { #expect(edge > firstEdge) }
                }
            }
            for size: Float in [20, 19, 20] {
                let frame = RenderFrame(width: 256, height: 256, clearColor: .zero,
                                        instances: group(SIMD4(4, 4, size, size)))
                let pixels = try capture(256, 256) { try renderer.draw(frame) }
                #expect(abs(Int(pixels.pixel(x: 14, y: 14).w) - 128) <= 1)
                #expect(renderer.layerStats().allocations == allocations + 1)
                let bytes = renderer.layerStats().bytes
                #expect(bytes == 64 * 64 * 8 || bytes == 64 * 64 * 4)
            }
        }
    }
}
#endif
