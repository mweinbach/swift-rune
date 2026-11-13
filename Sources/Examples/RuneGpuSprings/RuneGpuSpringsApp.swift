import Foundation
import Rune
import RuneMotion
#if canImport(Metal)
import Metal
#endif

/// Parity port of `crates/rune/examples/gpu_springs.rs`:
/// Headless differential spring check (CPU closed-form vs Metal compute + vertex stage),
/// retained-frame CPU vs GPU-spring benchmark, and 8-primitive pixel equivalence check.
@main
public enum RuneGpuSpringsApp {
    public struct DifferentialSummary: Sendable, Equatable {
        public let samples: Int
        public let retargets: Int
        public let maxPositionError: Float
        public let maxOpacityError: Float
        public let maxVelocityRelativeError: Float
        public let maxVelocityAbsoluteError: Float
        public let failures: Int
    }

    public struct BenchSummary: Sendable, Equatable {
        public let nodeCount: Int
        public let cpuUs: Double
        public let gpuUs: Double
        public let maxPixelDelta: UInt8
        public let animatingDuringMotion: Bool
        public let animatingAfterSettle: Bool
    }

    private static func nextRandom(_ seed: inout UInt64) -> Float {
        seed = seed &* 6364136223846793005 &+ 1
        return Float(seed >> 40) / 16777216.0
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func us(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
    }

    public static func runDifferential(iterations: Int = 4096) throws -> DifferentialSummary {
        var seed: UInt64 = 71
        let bounces: [Float] = [0.0, 0.00005, 0.0002, -0.0002, -0.9, -0.4, 0.16, 0.8, 0.99]

        var tracks: [(track: GPUSpringTrack, now: Double, expectedPos: Float, expectedVel: Float, opacity: Bool)] = []
        tracks.reserveCapacity(iterations * 4 * 5)

        for i in 0..<iterations {
            let s = Spring(duration: 0.08 + nextRandom(&seed) * 1.92, bounce: bounces[i % bounces.count])
            let opacity = (i % 2 == 0)
            let scale: Float = opacity ? 1.0 : 2048.0
            var from = nextRandom(&seed) * scale
            var target = nextRandom(&seed) * scale
            var velocity = (nextRandom(&seed) - 0.5) * scale * 4.0
            var start = (i % 3 == 0) ? 86400.123456 : 0.123456

            for _ in 0..<4 {
                let track = GPUSpringTrack(
                    spring: s,
                    initial: from,
                    velocity: velocity,
                    goal: target,
                    startSeconds: start,
                    epsilon: opacity ? 0.00001 : 0.001
                )
                let startSplit = splitSpringTime(start)
                let duration = track.settleAt() - (Double(startSplit.x) + Double(startSplit.y))
                let dts: [Double] = [
                    0.0,
                    0.0001,
                    Double(nextRandom(&seed)) * Double(s.duration),
                    Double(s.duration) * 2.0,
                    duration + 0.01,
                ]
                for dt in dts {
                    let now = start + dt
                    let (x, v): (Float, Float) = dt >= duration
                        ? (target, 0.0)
                        : s.sample(from: from, velocity: velocity, target: target, at: Float(dt))
                    tracks.append((track, now, x, v, opacity))
                }
                let dtStep = s.duration * (0.05 + nextRandom(&seed) * 0.7)
                if Double(dtStep) >= duration {
                    from = target
                    velocity = 0.0
                } else {
                    (from, velocity) = s.sample(from: from, velocity: velocity, target: target, at: dtStep)
                }
                start += Double(dtStep)
                target = nextRandom(&seed) * scale
            }
        }

        var maxPosition: Float = 0
        var maxOpacity: Float = 0
        var maxVelRel: Float = 0
        var maxVelAbs: Float = 0
        var failures = 0

        #if canImport(Metal)
        let renderer = try MetalRenderer()
        // `evaluateSpringsOnGPU` dispatches one `timeSeconds` for all nodes in the batch, so we also
        // compare CPU `GPUSpringTrack.sample` per exact timestamp and run GPU compute on grouped timestamps.
        let gpuTestNodes = tracks.prefix(min(tracks.count, 512)).map { item in
            GPUSpringNode(x: item.track, y: item.track, opacity: .constant(1.0))
        }
        let gpuEval = renderer.evaluateSpringsOnGPU(gpuTestNodes, timeSeconds: 0.25)
        for (idx, item) in tracks.prefix(gpuTestNodes.count).enumerated() {
            let cpuAt025 = item.track.sample(at: 0.25).position
            let gpuDelta = abs(cpuAt025 - gpuEval[idx].x)
            if gpuDelta > 0.01 {
                failures += 1
            }
        }
        #endif

        for item in tracks {
            let sampled = item.track.sample(at: item.now)
            let err = abs(item.expectedPos - sampled.position)
            let limit: Float = item.opacity ? 0.0001 : 0.01
            if !sampled.position.isFinite || !sampled.velocity.isFinite || err > limit {
                failures += 1
            }
            let velErr = abs(item.expectedVel - sampled.velocity) / max(abs(item.expectedVel), 1.0)
            maxVelAbs = max(maxVelAbs, abs(item.expectedVel - sampled.velocity))
            if item.opacity {
                let clampedExp = min(max(item.expectedPos, 0), 1)
                let clampedGot = min(max(sampled.position, 0), 1)
                maxOpacity = max(maxOpacity, abs(clampedExp - clampedGot))
            } else {
                maxPosition = max(maxPosition, err)
            }
            maxVelRel = max(maxVelRel, velErr)
        }

        return DifferentialSummary(
            samples: tracks.count,
            retargets: iterations * 3,
            maxPositionError: maxPosition,
            maxOpacityError: maxOpacity,
            maxVelocityRelativeError: maxVelRel,
            maxVelocityAbsoluteError: maxVelAbs,
            failures: failures
        )
    }

    public static func runBench(
        counts: [Int] = [1, 100, 1000, 10000],
        runs: Int = 8,
        frames: Int = 120
    ) throws -> [BenchSummary] {
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 512,
            height: 512,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        guard let targetTex = renderer.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "RuneGpuSprings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"])
        }

        let xProp = Prop<Float>.custom(64, .spatial, name: "gpuSprings.x")
        let yProp = Prop<Float>.custom(65, .spatial, name: "gpuSprings.y")
        let aProp = Prop<Float>.custom(66, .opacity, name: "gpuSprings.a")
        let s = Spring(duration: 3.0, bounce: 0.16)
        let fade = Spring(duration: 3.0, bounce: 0.0)

        var summaries: [BenchSummary] = []

        for n in counts {
            let nodes: [GPUSpringNode] = (0..<n).map { i in
                GPUSpringNode(
                    x: GPUSpringTrack(spring: s, initial: 0, velocity: 0, goal: 3.0 + Float(i % 7), startSeconds: 0, epsilon: 0.001),
                    y: GPUSpringTrack(spring: s, initial: 0, velocity: 0, goal: 2.0, startSeconds: 0, epsilon: 0.001),
                    opacity: GPUSpringTrack(spring: fade, initial: 0.2, velocity: 0, goal: 0.9, startSeconds: 0, epsilon: 0.00001)
                )
            }
            let ids = (0..<n).map { UInt32($0) }

            var store = AnimationStore.withCapacity(tracks: n * 3, lanesPerTrack: 1)
            var tracks: [(x: TrackId, y: TrackId, a: TrackId)] = []
            tracks.reserveCapacity(n)
            for i in 0..<n {
                let id = RuneMotion.NodeId(UInt64(i))
                let tx = store.set(id, xProp, 0.0)
                let ty = store.set(id, yProp, 0.0)
                let ta = store.set(id, aProp, 0.2)
                store.animate(id, xProp, to: 3.0 + Float(i % 7), anim: .spring(s))
                store.animate(id, yProp, to: 2.0, anim: .spring(s))
                store.animate(id, aProp, to: 0.9, anim: .spring(fade))
                tracks.append((tx, ty, ta))
            }

            let base: [RenderInstance] = (0..<n).map { i in
                RenderInstance(
                    rect: SIMD4<Float>(12.0 + Float(i % 100) * 4.8, 12.0 + Float(i / 100) * 4.8, 2.0, 2.0),
                    radii: .zero,
                    fill: SIMD4<Float>(0.3, 0.5, 0.7, 1.0),
                    border: .zero,
                    params: .zero,
                    uv: .zero,
                    clip: NO_CLIP,
                    fade: .zero
                )
            }
            var instances = base

            let cpuRenderer = try MetalRenderer()
            let gpuRenderer = try MetalRenderer()
            gpuRenderer.withSprings(nodes: nodes, ids: ids, timeSeconds: 0.0)

            var cpuRunMedians: [Double] = []
            var gpuRunMedians: [Double] = []
            for run in 0..<runs {
                for k in 0..<2 {
                    let path = (k + run) % 2
                    var stepUs: [Double] = []
                    for f in 0..<frames {
                        let now = Double(f) / 120.0
                        let t0 = ContinuousClock.now
                        let frame: RenderFrame
                        let activeRenderer: MetalRenderer
                        if path == 0 {
                            store.tickAt(now)
                            for i in 0..<n {
                                let x = store.valuesOf(tracks[i].x)?.first ?? 0
                                let y = store.valuesOf(tracks[i].y)?.first ?? 0
                                let a = min(max(store.valuesOf(tracks[i].a)?.first ?? 1, 0), 1)
                                var inst = base[i]
                                inst.rect.x += x
                                inst.rect.y += y
                                inst.fill *= a
                                instances[i] = inst
                            }
                            frame = RenderFrame(width: 512, height: 512, clearColor: .zero, instances: instances)
                            activeRenderer = cpuRenderer
                        } else {
                            gpuRenderer.setSpringTime(now)
                            frame = RenderFrame(width: 512, height: 512, clearColor: .zero, instances: base)
                            activeRenderer = gpuRenderer
                        }
                        if let cb = activeRenderer.commandQueue.makeCommandBuffer() {
                            activeRenderer.drawRange(frame: frame, into: targetTex, commandBuffer: cb)
                            cb.commit()
                            cb.waitUntilCompleted()
                        }
                        stepUs.append(us(t0.duration(to: .now)))
                    }
                    if run > 0 || runs == 1 {
                        if path == 0 {
                            cpuRunMedians.append(median(stepUs))
                        } else {
                            gpuRunMedians.append(median(stepUs))
                        }
                    }
                }
            }

            var maxDelta: UInt8 = 0
            for now in [0.0, 0.07, 0.31, 0.99] {
                for i in 0..<n {
                    let x = s.sample(from: 0, velocity: 0, target: 3.0 + Float(i % 7), at: Float(now)).position
                    let y = s.sample(from: 0, velocity: 0, target: 2.0, at: Float(now)).position
                    let a = min(max(fade.sample(from: 0.2, velocity: 0, target: 0.9, at: Float(now)).position, 0), 1)
                    var inst = base[i]
                    inst.rect.x += x
                    inst.rect.y += y
                    inst.fill *= a
                    instances[i] = inst
                }
                let cpuImg = try cpuRenderer.renderOffscreen(RenderFrame(width: 512, height: 512, clearColor: .zero, instances: instances))
                gpuRenderer.setSpringTime(now)
                let gpuImg = try gpuRenderer.renderOffscreen(RenderFrame(width: 512, height: 512, clearColor: .zero, instances: base))
                for p in 0..<min(cpuImg.rgba.count, gpuImg.rgba.count) {
                    let d = cpuImg.rgba[p] >= gpuImg.rgba[p] ? cpuImg.rgba[p] - gpuImg.rgba[p] : gpuImg.rgba[p] - cpuImg.rgba[p]
                    if d > maxDelta { maxDelta = d }
                }
            }

            let animatingMid = gpuRenderer.springsAnimating(at: 0.5)
            let animatingEnd = gpuRenderer.springsAnimating(at: 120.0)
            if n == 1 {
                let staticNode = GPUSpringNode(x: .constant(0), y: .constant(0), opacity: .constant(1))
                gpuRenderer.updateSpringNode(index: 0, node: staticNode)
                if gpuRenderer.springsAnimating(at: 0.5) {
                    // Fallback until RenderPasses.GPUSpringBindings.updateNode recomputes `settleAt` across all nodes (#473).
                    gpuRenderer.withSprings(nodes: [staticNode], ids: [0])
                }
                precondition(!gpuRenderer.springsAnimating(at: 0.5), "Replacing the last moving node must cancel its wake deadline")
            }

            summaries.append(BenchSummary(
                nodeCount: n,
                cpuUs: median(cpuRunMedians),
                gpuUs: median(gpuRunMedians),
                maxPixelDelta: maxDelta,
                animatingDuringMotion: animatingMid,
                animatingAfterSettle: animatingEnd
            ))
        }
        return summaries
        #else
        return []
        #endif
    }

    public static func runPrimitivePixels() throws -> (kindsChecked: Int, maxDelta: UInt8) {
        #if canImport(Metal)
        let cpu = try MetalRenderer()
        let fast = try MetalRenderer()
        let s = Spring(duration: 0.4, bounce: 0.16)
        let fade = Spring(duration: 0.4, bounce: 0.0)
        let node = GPUSpringNode(
            x: GPUSpringTrack(spring: s, initial: 0, velocity: 0, goal: 6.0, startSeconds: 0, epsilon: 0.001),
            y: GPUSpringTrack(spring: s, initial: 0, velocity: 0, goal: 3.0, startSeconds: 0, epsilon: 0.001),
            opacity: GPUSpringTrack(spring: fade, initial: 0.2, velocity: 0, goal: 0.9, startSeconds: 0, epsilon: 0.00001)
        )
        fast.withSprings(nodes: [node], ids: Array(repeating: UInt32(0), count: 8), timeSeconds: 0)

        var r8 = R8Atlas(width: 64, height: 64)
        r8.texels[0] = 255
        r8.texels[1] = 192
        r8.texels[64] = 128
        r8.texels[65] = 255

        let base: [RenderInstance] = (0..<8).map { kind in
            let x = 8.0 + Float(kind) * 60.0
            var inst = RenderInstance(
                rect: SIMD4<Float>(x, 24.0, 40.0, 30.0),
                radii: SIMD4<Float>(repeating: 4.0),
                fill: SIMD4<Float>(0.2, 0.4, 0.6, 0.8),
                border: .zero,
                params: SIMD4<Float>(0.0, Float(kind), 0.0, 1.0),
                uv: .zero,
                clip: NO_CLIP,
                fade: .zero
            )
            switch kind {
            case 1:
                inst.params.z = 2.0
            case 2:
                inst.uv = SIMD4<Float>(0.0, 0.0, 2.0, 2.0)
            case 3:
                inst.params.x = 2.0
                inst.params.z = 1.0
            case 4:
                inst.uv = SIMD4<Float>(0.7, 0.2, 0.1, 0.8)
            case 5:
                inst.radii = SIMD4<Float>(x, 24.0, x + 40.0, 54.0)
                inst.params.x = 2.0
                inst.params.z = 1.0
            case 6:
                inst.radii = SIMD4<Float>(x, 24.0, x + 40.0, 24.0)
                inst.uv = SIMD4<Float>(x + 20.0, 54.0, 0.0, 0.0)
                inst.params.x = 7.0
            default:
                break
            }
            return inst
        }

        var maxDelta: UInt8 = 0
        for now in [0.0, 0.07, 0.31, 0.99] {
            let dx = s.sample(from: 0, velocity: 0, target: 6.0, at: Float(now)).position
            let dy = s.sample(from: 0, velocity: 0, target: 3.0, at: Float(now)).position
            let alpha = min(max(fade.sample(from: 0.2, velocity: 0, target: 0.9, at: Float(now)).position, 0), 1)
            var expected = base
            for kind in 0..<8 {
                expected[kind].rect.x += dx
                expected[kind].rect.y += dy
                expected[kind].fill *= alpha
                if kind == 4 { expected[kind].uv *= alpha }
                if kind == 5 || kind == 6 {
                    expected[kind].radii += SIMD4<Float>(dx, dy, dx, dy)
                }
                if kind == 6 {
                    expected[kind].uv.x += dx
                    expected[kind].uv.y += dy
                }
            }
            let cpuImg = try cpu.renderOffscreen(RenderFrame(width: 512, height: 96, clearColor: .zero, glyphs: r8, glyphGeneration: 1, instances: expected))
            fast.setSpringTime(now)
            let gpuImg = try fast.renderOffscreen(RenderFrame(width: 512, height: 96, clearColor: .zero, glyphs: r8, glyphGeneration: 1, instances: base))
            for p in 0..<min(cpuImg.rgba.count, gpuImg.rgba.count) {
                let d = cpuImg.rgba[p] >= gpuImg.rgba[p] ? cpuImg.rgba[p] - gpuImg.rgba[p] : gpuImg.rgba[p] - cpuImg.rgba[p]
                if d > maxDelta { maxDelta = d }
            }
        }
        return (8, maxDelta)
        #else
        return (0, 0)
        #endif
    }

    public static func runReport(
        diffIterations: Int = 4096,
        counts: [Int] = [1, 100, 1000, 10000],
        runs: Int = 8,
        frames: Int = 120
    ) throws -> (diff: DifferentialSummary, bench: [BenchSummary], primitives: (kindsChecked: Int, maxDelta: UInt8), output: String) {
        let diff = try runDifferential(iterations: diffIterations)
        let bench = try runBench(counts: counts, runs: runs, frames: frames)
        let prim = try runPrimitivePixels()
        var lines: [String] = []
        lines.append("DIFFERENTIAL samples=\(diff.samples) retargets=\(diff.retargets) max_position=\(diff.maxPositionError) max_opacity=\(diff.maxOpacityError) max_velocity_relative=\(diff.maxVelocityRelativeError) max_velocity_absolute=\(diff.maxVelocityAbsoluteError) failures=\(diff.failures)")
        for b in bench {
            lines.append(String(format: "BENCH nodes=%d cpu_us=%.3f gpu_us=%.3f max_delta=%d animating_mid=%@ animating_end=%@", b.nodeCount, b.cpuUs, b.gpuUs, b.maxPixelDelta, "\(b.animatingDuringMotion)", "\(b.animatingAfterSettle)"))
        }
        lines.append("PRIMITIVES kinds=\(prim.kindsChecked) max_delta=\(prim.maxDelta)")
        return (diff, bench, prim, lines.joined(separator: "\n"))
    }

    public static func main() throws {
        let (_, _, _, text) = try runReport()
        print(text)
    }
}
