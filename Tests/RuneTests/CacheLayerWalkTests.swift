import RuneMotion
import Testing
@testable import Rune

@Suite("Runtime paint cache walk")
struct CacheLayerWalkTests {
    private enum Event: CaseIterable {
        case paint, zoom, commitZoom, wait, loseRaster, settle, overflow, nan

        var commits: Bool { self == .commitZoom || self == .overflow || self == .nan }
    }

    private struct Observation: Equatable {
        var scale: Float
        var since: Double = -.infinity

        // The upstream fixture distinguishes all bits, including NaN and the -infinity clock.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.scale.bitPattern == rhs.scale.bitPattern && lhs.since.bitPattern == rhs.since.bitPattern
        }
    }

    private struct Cache: Equatable {
        var raster: UInt32
        var observed: Observation
        var environment: UInt32
        var live: Bool
        var preserved: Bool
        var generation: UInt64
    }

    // Direct translation of the pre-state-machine `Old::paint` in cache_layer_tests.rs at
    // 842c28c2. Keep it independent of the runtime's scale tracking and cache eligibility.
    private struct Old {
        var cache: Cache?
        var tracked: Observation?
        var elided = false

        mutating func paint(scale: Float, now: Double, generation: UInt64, settled: Bool, resident: Bool) -> Bool {
            elided = false
            var moving = false
            if scale != 1 || tracked != nil {
                var seen = tracked ?? Observation(scale: scale)
                if settled { seen = Observation(scale: scale) }
                else if abs(seen.scale - scale) > 1e-5 { seen = Observation(scale: scale, since: now) }
                tracked = seen
                moving = now - seen.since < 0.1
            }
            var pending = moving
            if var previous = cache {
                previous.preserved = true
                if previous.generation != generation && abs(scale - Float(bitPattern: previous.raster)) > 1e-4 {
                    if abs(scale - previous.observed.scale) > 1e-4 {
                        previous.observed = Observation(scale: scale, since: now)
                    }
                    if now - previous.observed.since < 0.1 {
                        previous.live = true
                        cache = previous
                        return true
                    }
                }
                cache = previous
            }
            guard (32 * scale).rounded(.up) <= 4096 else { return pending }
            var seen = Observation(scale: scale)
            if let previous = cache {
                let envSame = abs(Float(bitPattern: previous.environment) - 1) <= 1e-4 && !settled
                if envSame {
                    seen = abs(scale - previous.observed.scale) > 1e-4
                        ? Observation(scale: scale, since: now) : previous.observed
                }
                let scaleDiff = abs(scale - Float(bitPattern: previous.raster)) > 1e-4
                let sameCommit = previous.generation == generation
                let settling = sameCommit && scaleDiff && envSame && resident && !previous.live
                    && (now - seen.since < 0.1 || moving)
                pending = pending || settling
                if resident && !previous.live && sameCommit && (!scaleDiff || settling) {
                    cache?.observed = seen
                    elided = true
                    return pending
                }
            }
            cache = Cache(raster: scale.bitPattern, observed: seen, environment: Float(1).bitPattern,
                          live: false, preserved: false, generation: generation)
            return pending
        }
    }

    private struct Fixture {
        let runtime: Runtime<Void>
        var sample: FrameOutput
        let id: NodeId

        init(pixelScale: Float, generation: Int = 1) throws {
            let rt = Runtime<Void>(state: (), viewport: Vec2(64, 64), pixelScale: pixelScale) { _, _ in
                el().key("cache").size(32, 32).cache().bg(.white)
            }
            _ = rt.frame(at: 0)
            for step in 1..<generation {
                rt.update { _, tx in tx.commit() }
                _ = rt.frame(at: Double(step) / 60)
            }
            runtime = rt
            id = try #require(rt.flatNodes.first { $0.key == "cache" }?.nodeId)
            sample = rt.stepToFrameOutput(at: Double(generation) / 60)
            _ = rt.buildRenderFrame(frameOut: sample, now: 0)
            try #require(rt.viewCommitCount == generation)
            try #require(rt.elSliceRenderState.nodeCaches[id] != nil)
        }

        func paint(scale: Float, now: Double, settled: Bool) throws -> RenderFrame {
            var frame = sample
            let index = try #require(frame.nodes.firstIndex { $0.id == id })
            frame.nodes[index].transform.sx = scale
            frame.nodes[index].transform.sy = scale
            frame.byId[id] = frame.nodes[index]
            runtime.lastWasSettled = settled
            return runtime.buildRenderFrame(frameOut: frame, now: now)
        }
    }

    @Test func everyPaintCacheWalkMatchesDev() throws {
        // Per-generation runtimes obtain their actual commit number from ordinary view commits.
        // Branches restore exactly the per-node observations that Rust restores before building.
        let generations = try (1...6).map { try Fixture(pixelScale: 1, generation: $0) }
        let sentinel = UInt64.max - 17
        var visited = 0
        func walk(_ old: Old, cache: ElNodeCacheEntry?, tracked: ElScaleSettle?,
                  scale: Float, now: Double, generation: Int, path: [Event]) throws {
            guard path.count < 5 else { return }
            for event in Event.allCases {
                let nextPath = path + [event]
                let finite = (-4...4).contains(scale) ? scale : 1.5
                let nextScale: Float = switch event {
                case .zoom, .commitZoom: 3 - finite
                case .overflow: .greatestFiniteMagnitude
                case .nan: .nan
                default: finite
                }
                let clock = now + (event == .wait ? 0.1 : 0.03125)
                let nextGen = generation + (event.commits ? 1 : 0)
                let fixture = generations[nextGen - 1]
                let rt = fixture.runtime
                let id = fixture.id
                var previous = cache
                // Swift records the retained signature instead of Rust's cached glyph count. Tag it
                // and provide matching renderer residency to detect reuse even for an empty glyph run.
                previous?.signature = sentinel
                rt.elSliceRenderState.nodeCaches[id] = previous
                rt.elSliceRenderState.scaleSettles[id] = tracked
                rt.residentCacheTracker.replaceAll(with: previous != nil && event != .loseRaster ? [id.rawValue: sentinel] : [:])
                let emitted = try fixture.paint(scale: nextScale, now: clock, settled: event == .settle)
                var expected = old
                let pending = expected.paint(scale: nextScale, now: clock, generation: UInt64(nextGen),
                                             settled: event == .settle, resident: event != .loseRaster)
                let observed = rt.elSliceRenderState.scaleSettles[id]
                let actualEntry = rt.elSliceRenderState.nodeCaches[id]
                let actual = actualEntry.map {
                    Cache(raster: $0.rasterScale.bitPattern, observed: Observation(scale: $0.scale, since: $0.since),
                          environment: $0.envScale.bitPattern, live: $0.isLivePhase,
                          preserved: $0.signature == sentinel, generation: $0.commitGen)
                }
                let reusedLayer = emitted.elidedLayers.contains { $0.node == id.rawValue && $0.signature == sentinel }
                try #require(reusedLayer == expected.elided, "retained render layer after \(nextPath)")
                try #require(rt.hasMovingScaleSettle == pending, "frame request after \(nextPath)")
                try #require(observed.map { Observation(scale: $0.scale, since: $0.since) } == expected.tracked,
                             "static scale after \(nextPath)")
                try #require(actual == expected.cache, "native cache after \(nextPath)")
                visited += 1
                try walk(expected, cache: actualEntry, tracked: observed, scale: nextScale, now: clock,
                         generation: nextGen, path: nextPath)
            }
        }
        try walk(Old(), cache: nil, tracked: nil, scale: 1, now: 0, generation: 1, path: [])
        #expect(visited == 37_448)
    }

    @Test func overflowingScaleOnTwoXStopsRequestingFrames() throws {
        let fixture = try Fixture(pixelScale: 2)
        let rt = fixture.runtime
        var now = 1.0
        var requested = 0
        func commitAndPaint() throws {
            now += 1.0 / 60
            let cache = rt.elSliceRenderState.nodeCaches[fixture.id]
            let scale = rt.elSliceRenderState.scaleSettles[fixture.id]
            rt.update { _, tx in tx.commit() }
            _ = rt.stepToFrameOutput(at: now)
            rt.elSliceRenderState.nodeCaches[fixture.id] = cache
            rt.elSliceRenderState.scaleSettles[fixture.id] = scale
            _ = try fixture.paint(scale: .greatestFiniteMagnitude, now: now, settled: false)
        }
        while now < 1.5 {
            try commitAndPaint()
            guard rt.hasMovingScaleSettle else { break }
            requested += 1
        }
        #expect(requested > 0 && requested < 12)
        #expect(rt.elSliceRenderState.nodeCaches[fixture.id]?.scale == .infinity)
        for _ in 0..<5 {
            try commitAndPaint()
            #expect(!rt.hasMovingScaleSettle)
        }
    }
}
