import Foundation
import Metal
import simd
import Testing
@testable import Rune

@Suite("Render Backdrop & Layer Planner Parity Tests")
struct RenderLayersAndBackdropTests {
    private static func makeRenderer() throws -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "Metal", code: -1)
        }
        return try MetalRenderer(device: device)
    }

    private static func solidRect(_ rect: SIMD4<Float>, _ color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) -> RenderInstance {
        RenderInstance(rect: rect, fill: color, clip: NO_CLIP)
    }

    private static func group(bounds: SIMD4<Float>, sigma: Float = 0) -> [RenderInstance] {
        [
            RenderInstance.beginLayer(
                bounds: bounds,
                clip: NO_CLIP,
                spec: LayerSpec(opacity: 0.5, blur: sigma)
            ),
            solidRect(bounds),
            RenderInstance.endLayer(),
        ]
    }

    private static func burst() -> [RenderInstance] {
        var out: [RenderInstance] = []
        out.reserveCapacity(1024 * 3)
        for idx in 0..<1024 {
            let x = Float(idx % 32) * 8.0
            let y = Float(idx / 32) * 8.0
            out.append(contentsOf: group(bounds: SIMD4<Float>(x, y, 8.0, 8.0), sigma: 0))
        }
        return out
    }

    private static func cachedRows(count: Int) -> [RenderInstance] {
        var out: [RenderInstance] = []
        out.reserveCapacity(count * 3)
        for row in 0..<count {
            let bounds = SIMD4<Float>(0, Float(row) * 16.0, 64.0, 16.0)
            var scope = RenderInstance.beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec())
            scope.params.w = 1.0
            scope.radii = packU64ToFloat4(UInt64(row))
            scope.uv = packU64ToFloat4(1)
            out.append(scope)
            out.append(solidRect(bounds))
            out.append(RenderInstance.endLayer())
        }
        return out
    }

    private static func isWarmSized(_ renderer: MetalRenderer) -> Bool {
        renderer.layersPool.planner.capacities().allSatisfy { $0 <= LayerPlannerConstants.warmCapacity }
    }

    // MARK: - render/backdrop_tests.rs (1 unported test)

    @Test("backdrop_slot_degrades_when_the_target_cannot_be_copied")
    func backdropSlotDegradesWhenTargetCannotBeCopied() throws {
        let renderer = try Self.makeRenderer()
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 32,
            height: 32,
            mipmapped: false
        )
        // Render-target-only texture without .shaderRead cannot serve as a readable backdrop source.
        texDesc.usage = [.renderTarget]
        texDesc.storageMode = .private
        guard let nonCopyableTarget = renderer.device.makeTexture(descriptor: texDesc) else {
            Issue.record("Failed to allocate renderTarget-only texture")
            return
        }

        var slot = Self.solidRect(SIMD4<Float>(0, 0, 16, 16), SIMD4<Float>(0, 0, 0, 1))
        slot.params = SIMD4<Float>(1.0, KIND_EFFECT, 0.0, 1.0)
        slot.clip = SIMD4<Float>(0, 0, 16, 16)

        var draws = 0
        var sawNilBackdrop = false
        guard let cmd = renderer.commandQueue.makeCommandBuffer() else {
            Issue.record("Failed to allocate command buffer")
            return
        }
        let frame = RenderFrame(width: 32, height: 32, srgbBlend: true, instances: [slot])
        renderer.drawWithBackdrop(frame: frame, into: nonCopyableTarget, commandBuffer: cmd) { phase, site in
            if case .draw = phase {
                sawNilBackdrop = (site.backdrop == nil)
                draws += 1
            }
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        #expect(cmd.error == nil)
        #expect(draws == 1)
        #expect(sawNilBackdrop)
    }

    // MARK: - render/layers/plan_frame_tests.rs (7 tests)

    @Test("a_layerless_frame_plans_nothing")
    func aLayerlessFramePlansNothing() throws {
        let renderer = try Self.makeRenderer()
        let emptyAtlas = R8Atlas(width: 1, height: 1, texels: [0])
        let burstInstances = Self.burst()
        _ = try renderer.renderOffscreen(
            RenderFrame(width: 256, height: 256, glyphs: emptyAtlas, instances: burstInstances)
        )
        #expect(renderer.layerStats().extraPasses == 1024)

        _ = try renderer.renderOffscreen(
            RenderFrame(width: 256, height: 256, glyphs: emptyAtlas, instances: [])
        )
        let stats = renderer.layerStats()
        #expect(stats.extraPasses == 0)
        #expect(renderer.layersPool.inUseCount == 0)
        #expect(renderer.layersPool.planner.dispositions.isEmpty)
        #expect(renderer.layersPool.planner.moves.isEmpty)
        #expect(Self.isWarmSized(renderer))
    }

    @Test("one_layer_left_of_a_burst_reads_no_spare")
    func oneLayerLeftOfBurstReadsNoSpare() throws {
        let renderer = try Self.makeRenderer()
        let emptyAtlas = R8Atlas(width: 1, height: 1, texels: [0])
        let burstInstances = Self.burst()
        _ = try renderer.renderOffscreen(
            RenderFrame(width: 256, height: 256, glyphs: emptyAtlas, instances: burstInstances)
        )
        let visits = renderer.layersPool.planner.parked.visits
        let oneLayer = Array(burstInstances.prefix(3))
        for _ in 0..<4 {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 256, height: 256, glyphs: emptyAtlas, instances: oneLayer)
            )
            #expect(renderer.layersPool.spareCount == 1023)
            #expect(renderer.layersPool.planner.parked.visits == visits)
            #expect(Self.isWarmSized(renderer))
        }
    }

    @Test("a_warm_menu_opens_and_closes_without_allocating")
    func warmMenuOpensAndClosesWithoutAllocating() throws {
        let renderer = try Self.makeRenderer()
        let emptyAtlas = R8Atlas(width: 1, height: 1, texels: [0])
        let menu = Self.group(bounds: SIMD4<Float>(4, 4, 40, 24))
        for instances in [menu, [], menu] {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 64, height: 64, glyphs: emptyAtlas, instances: instances)
            )
        }
        let warm = renderer.layersPool.planner.capacities()
        let allocations = renderer.layerStats().allocations
        for _ in 0..<4 {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 64, height: 64, glyphs: emptyAtlas, instances: [])
            )
            #expect(renderer.layersPool.planner.capacities() == warm)
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 64, height: 64, glyphs: emptyAtlas, instances: menu)
            )
            #expect(renderer.layersPool.planner.capacities() == warm)
            #expect(renderer.layerStats().allocations == allocations)
        }
    }

    @Test("a_list_showing_twelve_and_thirteen_cached_rows_by_turns_allocates_nothing")
    func listShowingTwelveAndThirteenCachedRowsByTurnsAllocatesNothing() throws {
        let renderer = try Self.makeRenderer()
        let emptyAtlas = R8Atlas(width: 1, height: 1, texels: [0])
        let all = Self.cachedRows(count: 160)
        let twelve = Self.cachedRows(count: 12)
        let thirteen = Self.cachedRows(count: 13)
        for instances in [all, thirteen, twelve, thirteen, twelve] {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 64, height: 2560, glyphs: emptyAtlas, instances: instances)
            )
        }
        #expect(renderer.layersPool.retainedCount >= 148)
        let warm = renderer.layersPool.planner.capacities()
        let allocations = renderer.layerStats().allocations
        for _ in 0..<4 {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 64, height: 2560, glyphs: emptyAtlas, instances: thirteen)
            )
            let hit13 = renderer.layersPool.planner.dispositions[12]
            if case .cached = hit13 {} else {
                Issue.record("Expected 13th row disposition to be .cached, got \(hit13)")
            }
            #expect(renderer.layersPool.planner.capacities() == warm)
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 64, height: 2560, glyphs: emptyAtlas, instances: twelve)
            )
            #expect(renderer.layersPool.planner.capacities() == warm)
            #expect(renderer.layerStats().allocations == allocations)
        }
    }

    @Test("a_menu_after_a_burst_opens_and_closes_without_allocating")
    func menuAfterBurstOpensAndClosesWithoutAllocating() throws {
        let renderer = try Self.makeRenderer()
        let emptyAtlas = R8Atlas(width: 1, height: 1, texels: [0])
        let burstInstances = Self.burst()
        let menu = Array(burstInstances.prefix(3))
        for instances in [burstInstances, [], menu, [], menu] {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 256, height: 256, glyphs: emptyAtlas, instances: instances)
            )
        }
        let warm = renderer.layersPool.planner.capacities()
        let allocations = renderer.layerStats().allocations
        for _ in 0..<4 {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 256, height: 256, glyphs: emptyAtlas, instances: [])
            )
            #expect(renderer.layersPool.spareCount == 1024)
            #expect(renderer.layersPool.planner.capacities() == warm)
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 256, height: 256, glyphs: emptyAtlas, instances: menu)
            )
            #expect(renderer.layersPool.planner.capacities() == warm)
            #expect(renderer.layerStats().allocations == allocations)
        }
    }

    @Test("an_empty_frame_after_an_empty_frame_does_nothing")
    func emptyFrameAfterEmptyFrameDoesNothing() throws {
        let renderer = try Self.makeRenderer()
        let emptyAtlas = R8Atlas(width: 1, height: 1, texels: [0])
        _ = try renderer.renderOffscreen(
            RenderFrame(width: 64, height: 64, glyphs: emptyAtlas, instances: Self.group(bounds: SIMD4<Float>(4, 4, 40, 24)))
        )
        _ = try renderer.renderOffscreen(
            RenderFrame(width: 64, height: 64, glyphs: emptyAtlas, instances: [])
        )
        #expect(renderer.layersPool.planner.settles == 1)
        for _ in 0..<3 {
            _ = try renderer.renderOffscreen(
                RenderFrame(width: 64, height: 64, glyphs: emptyAtlas, instances: [])
            )
            #expect(renderer.layersPool.planner.settles == 1)
        }
    }

    @Test("a_frame_never_holds_more_layer_textures_than_dev")
    func frameNeverHoldsMoreLayerTexturesThanDev() throws {
        let renderer = try Self.makeRenderer()
        let emptyAtlas = R8Atlas(width: 1, height: 1, texels: [0])
        let one = SIMD4<Float>(4, 4, 2000, 2000)
        let two = SIMD4<Float>(8, 8, 2000, 2000)

        _ = try renderer.renderOffscreen(
            RenderFrame(width: 2048, height: 2048, glyphs: emptyAtlas, instances: Self.group(bounds: one, sigma: 1.0))
        )
        #expect(renderer.layersPool.peakBytes <= UInt64(64 << 20))

        var siblingInstances = Self.group(bounds: one, sigma: 0.0)
        siblingInstances.append(contentsOf: Self.group(bounds: two, sigma: 0.0))
        _ = try renderer.renderOffscreen(
            RenderFrame(width: 2048, height: 2048, glyphs: emptyAtlas, instances: siblingInstances)
        )
        #expect(renderer.layersPool.peakBytes <= UInt64(64 << 20))
    }

    // MARK: - render/layers/plan_tests.rs (5 tests)

    fileprivate struct WalkSpec {
        var parent: Int? = nil
        var edges: SIMD4<Float>
        var vis: SIMD4<Float>
        var cache: (UInt64, UInt64)? = nil
        var opacity: Float = 1.0
        var blend: RenderBlend = .sourceOver
        var blur: Float = 0.0
        var fade: UInt32 = 0
        var clip: SIMD4<Float> = NO_CLIP
        var turn: (Float, SIMD2<Float>)? = nil
        var hole: SIMD4<Float> = .zero
        var draws: UInt32 = 0

        static func plain(_ edges: SIMD4<Float>, _ vis: SIMD4<Float>) -> WalkSpec {
            WalkSpec(edges: edges, vis: vis)
        }

        static func cached(_ edges: SIMD4<Float>, _ vis: SIMD4<Float>, _ cache: (UInt64, UInt64)) -> WalkSpec {
            WalkSpec(edges: edges, vis: vis, cache: cache)
        }

        static func child(_ parent: Int, _ edges: SIMD4<Float>, _ vis: SIMD4<Float>) -> WalkSpec {
            WalkSpec(parent: parent, edges: edges, vis: vis)
        }
    }

    private enum OldShow: Equatable {
        case hidden, covered, inline, render, cached
    }

    private struct OldLayer {
        var begin: UInt32
        var end: UInt32
        var parent: Int?
        var edges: SIMD4<Float>
        var vis: SIMD4<Float>
        var rect: SIMD4<Float> = .zero
        var cache: (UInt64, UInt64)?
        var cacheTarget: (UInt64, UInt64)? = nil
        var opacity: Float
        var blend: RenderBlend
        var blur: Float
        var fade: SIMD4<UInt32>
        var clip: SIMD4<Float>
        var turn: (Float, SIMD2<Float>)?
        var hole: SIMD4<Float>
        var show: OldShow

        init(_ l: LayerPlanScope) {
            begin = l.begin
            end = l.end
            parent = l.parent
            edges = l.edges
            vis = l.vis
            cache = l.cache
            opacity = l.opacity
            blend = l.blend
            blur = l.blur
            fade = l.fade
            clip = l.clip
            turn = l.turn
            hole = l.hole
            show = switch l.planned {
            case .hidden: .hidden
            case .covered: .covered
            case .inline: .inline
            }
        }
    }

    private struct OldScratch: Equatable {
        var work: Bool = false
    }

    private struct OldHeld: Equatable, LayerHeldDescribing {
        var size: SIMD2<UInt32>
        var cache: (UInt64, UInt64)? = nil
        var lastUsed: UInt64 = 0
        var content: SIMD2<Float> = .zero
        var blur: OldScratch? = nil
        var quad: (Float, SIMD2<Float>)? = nil

        static func == (lhs: OldHeld, rhs: OldHeld) -> Bool {
            lhs.size == rhs.size &&
            lhs.cache?.0 == rhs.cache?.0 &&
            lhs.cache?.1 == rhs.cache?.1 &&
            lhs.lastUsed == rhs.lastUsed &&
            lhs.content == rhs.content &&
            lhs.blur == rhs.blur &&
            lhs.quad?.0 == rhs.quad?.0 &&
            lhs.quad?.1 == rhs.quad?.1
        }

        func bytes() -> UInt64 {
            let texture = UInt64(size.x) * UInt64(size.y) * 8
            let scratch = blur.map { $0.work ? 2 * texture : texture } ?? 0
            return texture + scratch
        }

        mutating func applyBlur(_ sigma: Float, content: SIMD2<Float>) {
            var scratch = blur ?? OldScratch()
            let reduction = min(max(sigma / 3.0, 1.0), 8.0)
            let reduced = SIMD2<Float>(ceil(content.x / reduction), ceil(content.y / reduction))
            if reduced != content { scratch.work = true }
            blur = scratch
        }

        func held() -> LayerHeld {
            LayerHeld(size: size, bytes: bytes(), cache: cache, lastUsed: lastUsed, content: content)
        }
    }

    private struct OldPools: Equatable {
        var retained: [OldHeld] = []
        var spare: [OldHeld] = []
        var slots: [OldHeld?] = []

        mutating func swapRemoveRetained(_ idx: Int) -> OldHeld {
            let removed = retained[idx]
            if idx < retained.count - 1 { retained[idx] = retained[retained.count - 1] }
            retained.removeLast()
            return removed
        }

        mutating func swapRemoveSpare(_ idx: Int) -> OldHeld {
            let removed = spare[idx]
            if idx < spare.count - 1 { spare[idx] = spare[spare.count - 1] }
            spare.removeLast()
            return removed
        }

        mutating func park(_ held: OldHeld) {
            var t = held
            t.cache = nil
            spare.append(t)
            var bytes = spare.reduce(UInt64(0)) { $0 + $1.bytes() }
            while bytes > LayerPlannerConstants.spareBytes {
                var oldest = 0
                for i in 1..<spare.count where spare[i].lastUsed < spare[oldest].lastUsed { oldest = i }
                bytes -= swapRemoveSpare(oldest).bytes()
            }
        }

        mutating func release(_ index: Int) {
            if let t = slots[index] {
                slots[index] = nil
                park(t)
            }
        }

        mutating func trimRetained(activeBytes: UInt64, budget: UInt64) {
            let available = budget >= activeBytes ? (budget - activeBytes) : 0
            var bytes = retained.reduce(UInt64(0)) { $0 + $1.bytes() }
            while bytes > available {
                var oldest = 0
                for i in 1..<retained.count where retained[i].lastUsed < retained[oldest].lastUsed { oldest = i }
                bytes -= swapRemoveRetained(oldest).bytes()
            }
        }

        mutating func takeSpare(width: UInt32, height: UInt32) -> OldHeld? {
            guard let at = spare.firstIndex(where: { t in
                t.size.x >= width && t.size.y >= height &&
                    UInt64(t.size.x) * UInt64(t.size.y) <= 2 * UInt64(max(width, 64)) * UInt64(max(height, 64))
            }) else { return nil }
            return swapRemoveSpare(at)
        }

        mutating func passes(_ plan: inout [OldLayer], isolate: Bool, maxDim: UInt32, budget: UInt64, stamp: UInt64) {
            let bpp = LayerPlannerConstants.bpp
            var activeCacheBytes: UInt64 = 0
            for index in 0..<plan.count {
                let e = plan[index].edges
                plan[index].rect = LayerPlannerConstants.rectOf(e)
                if plan[index].rect.z == 0 || plan[index].rect.w == 0 {
                    plan[index].show = .hidden
                }
                if !isolate || plan[index].show != .inline { continue }
                guard let key = plan[index].cache else { continue }
                guard let pos = retained.firstIndex(where: { $0.cache?.0 == key.0 && $0.cache?.1 == key.1 }) else { continue }
                let tBytes = retained[pos].bytes()
                let overBudget = activeCacheBytes + tBytes > budget
                if overBudget && plan[index].begin + 1 < plan[index].end { continue }
                var t = swapRemoveRetained(pos)
                if overBudget {
                    t.cache = nil
                } else {
                    t.lastUsed = stamp
                    activeCacheBytes += tBytes
                }
                t.quad = plan[index].turn
                plan[index].show = .cached
                plan[index].cacheTarget = t.cache
                slots[index] = t
            }

            for index in 0..<plan.count {
                let parentShow = plan[index].parent.map { plan[$0].show }
                if plan[index].show == .cached { continue }
                if parentShow == .hidden { plan[index].show = .hidden; continue }
                if plan[index].show == .covered {
                    plan[index].show = (parentShow == .covered || parentShow == .cached) ? .covered : .inline
                }
            }

            for index in 0..<plan.count {
                switch plan[index].show {
                case .inline: break
                case .cached, .render: continue
                case .hidden, .covered: release(index); continue
                }
                let additiveParent = plan[index].parent.map { plan[$0].blend == .plusLighter } ?? false
                if !isolate { release(index); continue }
                var bounds = plan[index].rect
                var (bucket, width, height) = LayerPlannerConstants.bucketOf(bounds)
                var cacheTarget: (UInt64, UInt64)? = nil
                if let req = plan[index].cache {
                    let previous = retained.firstIndex(where: { $0.cache?.0 == req.0 })
                    let neededBytes = UInt64(bucket.x) * UInt64(bucket.y) * bpp
                    if bucket.x <= maxDim && bucket.y <= maxDim && activeCacheBytes + neededBytes <= budget {
                        activeCacheBytes += neededBytes
                        cacheTarget = req
                        if let pos = previous {
                            release(index)
                            slots[index] = swapRemoveRetained(pos)
                        } else {
                            trimRetained(activeBytes: activeCacheBytes, budget: budget)
                        }
                    } else {
                        if let pos = previous {
                            _ = swapRemoveRetained(pos)
                        }
                        bounds = LayerPlannerConstants.rectOf(plan[index].vis)
                        plan[index].rect = bounds
                        (bucket, width, height) = LayerPlannerConstants.bucketOf(bounds)
                    }
                }
                let l = plan[index]
                let scissor = l.clip == NO_CLIP || (
                    l.fade == .zero &&
                    abs(l.clip.x - round(l.clip.x)) < 1e-3 &&
                    abs(l.clip.y - round(l.clip.y)) < 1e-3 &&
                    abs(l.clip.z - round(l.clip.z)) < 1e-3 &&
                    abs(l.clip.w - round(l.clip.w)) < 1e-3
                )
                if cacheTarget == nil && l.opacity == 1.0 && l.blend == .sourceOver && !additiveParent
                    && l.blur == 0.0 && l.fade.w == 0 && l.turn == nil && l.hole.w == 0.0 && scissor {
                    release(index)
                    continue
                }
                plan[index].show = .render
                plan[index].cacheTarget = cacheTarget
                let fits = slots[index].map { t in
                    t.size.x >= width && t.size.y >= height && (
                        t.size == bucket ||
                        UInt64(t.size.x) * UInt64(t.size.y) <= 2 * UInt64(width) * UInt64(height)
                    )
                } ?? false
                if !fits {
                    release(index)
                    if let sp = takeSpare(width: width, height: height) {
                        slots[index] = sp
                    }
                }
                if slots[index] == nil {
                    slots[index] = OldHeld(size: bucket)
                }
                let sigma = plan[index].blur
                let b = plan[index].rect
                var t = slots[index]!
                t.cache = cacheTarget
                t.lastUsed = stamp
                t.content = SIMD2<Float>(b.z, b.w)
                t.quad = plan[index].turn
                if sigma > 0.0 {
                    t.applyBlur(sigma, content: t.content)
                } else {
                    t.blur = nil
                }
                slots[index] = t
            }
            trimRetained(activeBytes: activeCacheBytes, budget: budget)
        }
    }

    private static func makeWalkScenes() -> [[WalkSpec]] {
        let win = SIMD4<Float>(0, 0, 32, 16)
        return [
            [
                .cached(SIMD4<Float>(4, 2, 24, 12), win, (7, 1)),
                { var s = WalkSpec.child(0, SIMD4<Float>(8, 4, 16, 6), win); s.opacity = 0.5; return s }(),
            ],
            [
                .cached(SIMD4<Float>(0, 0, 16, 8), win, (11, 1)),
                .cached(SIMD4<Float>(16, 8, 32, 16), win, (12, 3)),
            ],
            [
                .cached(SIMD4<Float>(2, 1, 28, 14), win, (21, 2)),
                .cached(SIMD4<Float>(4, 2, 12, 8), win, (22, 5)).withParent(0),
                { var s = WalkSpec.child(1, SIMD4<Float>(6, 3, 8, 4), win); s.opacity = 0.75; return s }(),
            ],
            [
                .plain(SIMD4<Float>(0, 0, 8, 8), win),
                { var s = WalkSpec.child(0, SIMD4<Float>(4, 2, 16, 8), win); s.clip = SIMD4<Float>(4.5, 2, 20, 10); return s }(),
                { var s = WalkSpec.plain(SIMD4<Float>(8, 0, 16, 8), win); s.blur = 2.0; return s }(),
                { var s = WalkSpec.plain(SIMD4<Float>(12, 4, 8, 8), win); s.blend = .plusLighter; return s }(),
                { var s = WalkSpec.child(0, SIMD4<Float>(8, 4, 16, 8), win); s.clip = SIMD4<Float>(8, 4, 24, 12); return s }(),
            ],
            [
                .cached(SIMD4<Float>(4, 2, 26, 13), win, (7, 1)),
                { var s = WalkSpec.child(0, SIMD4<Float>(8, 4, 18, 7), win); s.opacity = 0.5; return s }(),
            ],
            [
                { var s = WalkSpec.cached(SIMD4<Float>(8, 4, 16, 8), win, (31, 4)); s.turn = (0.3, SIMD2<Float>(16, 8)); return s }(),
                { var s = WalkSpec.plain(SIMD4<Float>(6, 2, 12, 12), win); s.fade = 1200; s.hole = SIMD4<Float>(16, 8, 6, 8); return s }(),
            ],
            [
                { var s = WalkSpec.cached(SIMD4<Float>(4, 2, 68, 66), win, (41, 1)); s.blur = 12.0; return s }(),
                { var s = WalkSpec.child(0, SIMD4<Float>(8, 4, 16, 6), win); s.opacity = 0.5; return s }(),
            ],
            [
                { var s = WalkSpec.cached(SIMD4<Float>(0, 0, 16, 8), win, (11, 1)); s.draws = 1; return s }(),
                .cached(SIMD4<Float>(16, 8, 32, 16), win, (12, 3)),
            ],
        ]
    }

    private static func marks(of scene: [WalkSpec]) -> ([UInt32], [UInt32]) {
        var at: UInt32 = 0
        var begin = [UInt32](repeating: 0, count: scene.count)
        var end = [UInt32](repeating: 0, count: scene.count)
        func visit(_ idx: Int) {
            begin[idx] = at
            at += 1 + scene[idx].draws
            for (child, spec) in scene.enumerated() where spec.parent == idx {
                visit(child)
            }
            end[idx] = at
            at += 1
        }
        for (idx, spec) in scene.enumerated() where spec.parent == nil {
            visit(idx)
        }
        return (begin, end)
    }

    private static func planOf(scene: [WalkSpec], held: [LayerHeld]) -> [LayerPlanScope] {
        let (begin, end) = marks(of: scene)
        var planned: [LayerPlanPlanned] = []
        return scene.enumerated().map { idx, spec in
            let above = spec.parent.map { planned[$0] }
            let covered = spec.parent.map { p in
                scene[p].cache.map { key in held.contains(where: { $0.cache?.0 == key.0 && $0.cache?.1 == key.1 }) } ?? false
            } ?? false
            let pState: LayerPlanPlanned = if spec.opacity == 0 {
                .hidden
            } else if above == .hidden {
                .hidden
            } else if above == .covered || covered {
                .covered
            } else {
                .inline
            }
            planned.append(pState)
            return LayerPlanScope(
                begin: begin[idx],
                end: end[idx],
                parent: spec.parent,
                edges: spec.edges,
                vis: spec.vis,
                clip: spec.clip,
                fade: SIMD4<UInt32>(0, 0, 0, spec.fade),
                opacity: spec.opacity,
                blend: spec.blend,
                blur: spec.blur,
                cache: spec.cache,
                planned: pState,
                turn: spec.turn,
                free: spec.turn != nil,
                frame: spec.edges,
                hole: spec.hole
            )
        }
    }

    private static func apply(_ pools: inout OldPools, moves: [LayerPoolMove]) {
        for m in moves {
            switch m {
            case .park(let slot):
                if var t = pools.slots[slot] {
                    pools.slots[slot] = nil
                    t.cache = nil
                    pools.spare.append(t)
                }
            case .set(let slot, let from):
                switch from {
                case .retained(let at): pools.slots[slot] = pools.swapRemoveRetained(at)
                case .spare(let at): pools.slots[slot] = pools.swapRemoveSpare(at)
                }
            case .create(let slot, let size):
                pools.slots[slot] = OldHeld(size: size)
            case .unblur(let slot):
                if var t = pools.slots[slot] {
                    t.blur = nil
                    pools.slots[slot] = t
                }
            case .drop(.retained(let at)):
                _ = pools.swapRemoveRetained(at)
            case .drop(.spare(let at)):
                _ = pools.swapRemoveSpare(at)
            }
        }
    }

    private static func finish(_ pools: inout OldPools, plan: [LayerPlanScope], dispositions: [LayerDisposition], stamp: UInt64) {
        for (idx, disp) in dispositions.enumerated() {
            guard var t = pools.slots[idx] else { continue }
            switch disp {
            case .cached(_, let cache):
                t.cache = cache
                if cache != nil { t.lastUsed = stamp }
                t.quad = plan[idx].turn
            case .render(let rect, let cache):
                t.cache = cache
                t.lastUsed = stamp
                t.content = SIMD2<Float>(rect.z, rect.w)
                t.quad = plan[idx].turn
                if plan[idx].blur > 0.0 {
                    t.applyBlur(plan[idx].blur, content: t.content)
                }
            case .skip, .inline:
                break
            }
            pools.slots[idx] = t
        }
    }

    @discardableResult
    private static func runPlanFrame(
        planner: inout LayerPlanner,
        pools: OldPools,
        oldPools: inout OldPools,
        scene: [WalkSpec],
        isolate: Bool,
        budget: UInt64,
        stamp: UInt64
    ) -> [LayerDisposition] {
        let previous = pools.slots.count
        var before = pools
        for i in before.slots.indices {
            if let t = before.slots[i], t.cache != nil {
                before.slots[i] = nil
                before.retained.append(t)
            }
        }
        while before.slots.count > scene.count {
            if let t = before.slots.removeLast() { before.park(t) }
        }
        while before.slots.count < scene.count {
            before.slots.append(nil)
        }

        let layers = planOf(scene: scene, held: before.retained.map { $0.held() })
        oldPools = before
        var oldPlan = layers.map(OldLayer.init)
        oldPools.passes(&oldPlan, isolate: isolate, maxDim: 4096, budget: budget, stamp: stamp)

        var decisions: [LayerDisposition] = []
        if scene.isEmpty {
            before.trimRetained(activeBytes: 0, budget: budget)
        } else {
            let snap = LayerPoolSnapshot(slots: before.slots, retained: before.retained, spare: before.spare)
            planner.decide(plan: layers, pools: snap, budget: budget, isolate: isolate, maxDim: 4096)
            for (index, old) in oldPlan.enumerated() {
                let got = planner.dispositions[index]
                switch (old.show, got) {
                case (.hidden, .skip), (.covered, .skip), (.inline, .inline):
                    break
                case (.render, .render(let rect, let cache)), (.cached, .cached(let rect, let cache)):
                    #expect(rect == old.rect)
                    #expect(cache?.0 == old.cacheTarget?.0 && cache?.1 == old.cacheTarget?.1)
                default:
                    Issue.record("layer \(index) at \(stamp): dev says \(old.show), plan says \(got)")
                }
            }
            apply(&before, moves: planner.moves)
            finish(&before, plan: layers, dispositions: planner.dispositions, stamp: stamp)
            decisions = planner.dispositions
        }
        #expect(before == oldPools)
        if scene.count < previous {
            planner.settle(len: scene.count, retained: before.retained.count, spare: before.spare.count)
        }
        return decisions
    }

    @Test("every_frame_walk_matches_dev")
    func everyFrameWalkMatchesDev() {
        var scenes = Self.makeWalkScenes()
        let tight: UInt64 = 40_000
        let defaultBudget = UInt64(DEFAULT_LAYER_CACHE_BUDGET)
        var events: [(Int, UInt64, Bool)] = [
            (0, defaultBudget, true), (1, defaultBudget, true), (1, tight, true),
            (0, 1, true), (2, defaultBudget, true), (3, defaultBudget, true),
            (6, tight, true), (4, defaultBudget, true), (5, defaultBudget, true),
            (0, tight, true), (1, defaultBudget, false),
            (7, defaultBudget, true), (7, 1, true),
        ]
        let emptyIdx = scenes.count
        scenes.append([])
        events.append((emptyIdx, defaultBudget, true))

        func walk(pools: OldPools, planner: LayerPlanner, stamp: UInt64, depth: Int) -> Bool {
            if depth == 0 { return false }
            var sawSplitBudget = false
            for (sceneIdx, budget, isolate) in events {
                var after = OldPools()
                var nextPlanner = planner
                let nextStamp = stamp + 1
                let decisions = Self.runPlanFrame(
                    planner: &nextPlanner,
                    pools: pools,
                    oldPools: &after,
                    scene: scenes[sceneIdx],
                    isolate: isolate,
                    budget: budget,
                    stamp: nextStamp
                )
                if sceneIdx == 1 && budget == tight && decisions.count == 2,
                   case .cached(_, let c0) = decisions[0], c0?.0 == 11 && c0?.1 == 1,
                   case .cached(_, let c1) = decisions[1], c1 == nil {
                    sawSplitBudget = true
                }
                if walk(pools: after, planner: nextPlanner, stamp: nextStamp, depth: depth - 1) {
                    sawSplitBudget = true
                }
                #expect(after.slots.count <= scenes[sceneIdx].count)
            }
            return sawSplitBudget
        }

        // Depth 3 covers all 3-step transitions including tight-budget sibling cache split (>3,000 walks).
        let sawSplit = walk(pools: OldPools(), planner: LayerPlanner(), stamp: 0, depth: 3)
        #expect(sawSplit)
    }

    @Test("a_kept_target_costs_its_texture_and_its_blur")
    func keptTargetCostsItsTextureAndItsBlur() {
        var direct = OldHeld(size: SIMD2<UInt32>(64, 64))
        var reduced = OldHeld(size: SIMD2<UInt32>(64, 64))
        direct.applyBlur(1.0, content: SIMD2<Float>(64, 64))
        reduced.applyBlur(12.0, content: SIMD2<Float>(64, 64))
        #expect(direct.bytes() == 65_536)
        #expect(reduced.bytes() == 98_304)
    }

    @Test("a_closed_cache_is_still_kept_when_its_layers_come_back")
    func closedCacheIsStillKeptWhenLayersComeBack() {
        let scenes = Self.makeWalkScenes()
        var pools = OldPools()
        var after = OldPools()
        var planner = LayerPlanner()
        _ = Self.runPlanFrame(planner: &planner, pools: pools, oldPools: &after, scene: scenes[0], isolate: true, budget: UInt64(DEFAULT_LAYER_CACHE_BUDGET), stamp: 1)
        swap(&pools, &after)
        _ = Self.runPlanFrame(planner: &planner, pools: pools, oldPools: &after, scene: [], isolate: true, budget: UInt64(DEFAULT_LAYER_CACHE_BUDGET), stamp: 2)
        swap(&pools, &after)
        #expect(pools.retained.contains(where: { $0.cache?.0 == 7 && $0.cache?.1 == 1 }))
        let decisions = Self.runPlanFrame(planner: &planner, pools: pools, oldPools: &after, scene: scenes[0], isolate: true, budget: UInt64(DEFAULT_LAYER_CACHE_BUDGET), stamp: 3)
        if case .cached = decisions[0] {} else {
            Issue.record("Expected reopened closed cache to hit, got \(decisions[0])")
        }
    }

    @Test("a_pool_view_moves_its_targets_as_a_vec_does")
    func poolViewMovesTargetsAsVecDoes() {
        func swapRemove(_ arr: inout [LayerPoolSource], at idx: Int) -> LayerPoolSource {
            let v = arr[idx]
            if idx < arr.count - 1 { arr[idx] = arr[arr.count - 1] }
            arr.removeLast()
            return v
        }
        func walk(view: LayerPoolView, model: [LayerPoolSource], fresh: Int, depth: Int) {
            #expect(view.len == model.count)
            for (place, src) in model.enumerated() {
                #expect(view.source(place) == src)
            }
            if depth == 0 { return }
            var parked = view
            var pushed = model
            parked.push(.slot(fresh))
            pushed.append(.slot(fresh))
            walk(view: parked, model: pushed, fresh: fresh + 1, depth: depth - 1)
            for at in 0..<model.count {
                var v = view
                var m = model
                #expect(v.swapRemove(at) == swapRemove(&m, at: at))
                walk(view: v, model: m, fresh: fresh + 1, depth: depth - 1)
            }
        }
        for len in 0..<4 {
            var view = LayerPoolView(ownerKind: .spare)
            view.reset(len)
            let model = (0..<len).map { LayerPoolSource.spare($0) }
            walk(view: view, model: model, fresh: 0, depth: 5)
        }
    }

    @Test("a_cached_leaf_with_a_draw_keeps_its_place_under_the_budget")
    func cachedLeafWithDrawKeepsItsPlaceUnderBudget() {
        let scenes = Self.makeWalkScenes()
        var pools = OldPools()
        var after = OldPools()
        var planner = LayerPlanner()
        _ = Self.runPlanFrame(planner: &planner, pools: pools, oldPools: &after, scene: scenes[7], isolate: true, budget: UInt64(DEFAULT_LAYER_CACHE_BUDGET), stamp: 1)
        swap(&pools, &after)
        let (begin, end) = Self.marks(of: scenes[7])
        #expect(end[0] - begin[0] == 2)
        #expect(end[1] - begin[1] == 1)
        let decisions = Self.runPlanFrame(planner: &planner, pools: pools, oldPools: &after, scene: scenes[7], isolate: true, budget: 1, stamp: 2)
        #expect(decisions[0] == .inline)
        let stillKept0 = after.retained.contains { $0.cache?.0 == 11 && $0.cache?.1 == 1 }
            || after.slots.compactMap { $0 }.contains { $0.cache?.0 == 11 && $0.cache?.1 == 1 }
        #expect(!stillKept0)
        if case .cached(_, let c1) = decisions[1] {
            #expect(c1 == nil)
        } else {
            Issue.record("Expected empty cached leaf to borrow texture, got \(decisions[1])")
        }
    }
}

fileprivate extension RenderLayersAndBackdropTests.WalkSpec {
    func withParent(_ parent: Int?) -> Self {
        var copy = self
        copy.parent = parent
        return copy
    }
}
