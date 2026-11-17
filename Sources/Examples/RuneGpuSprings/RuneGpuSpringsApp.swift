import Foundation
import Rune
import RuneMotion
#if canImport(Metal)
import Metal
private typealias SpringFrameRenderer = MetalRenderer
#elseif os(Linux) || os(Windows)
private typealias SpringFrameRenderer = GLSpringFrameRenderer
#endif

/// Parity port of `crates/rune/examples/gpu_springs.rs`:
/// Headless differential spring check (CPU closed form vs GPU vertex shader),
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
        guard iterations >= 0, iterations <= Int.max / 20 else {
            throw NSError(domain: "RuneGpuSprings", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid spring sample count"])
        }
        if iterations == 0 {
            return DifferentialSummary(samples: 0, retargets: 0, maxPositionError: 0, maxOpacityError: 0,
                                       maxVelocityRelativeError: 0, maxVelocityAbsoluteError: 0, failures: 0)
        }
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
        struct GPUQuery {
            var track: GPUSpringTrack
            var time: SIMD4<Float>
        }

        let queries: [GPUQuery] = tracks.map { item in
            let split = splitSpringTime(item.now)
            return GPUQuery(
                track: item.track,
                time: SIMD4<Float>(split.x, split.y, item.opacity ? 1.0 : 0.0, 0.0)
            )
        }
        let width = 256
        let height = max(1, (queries.count + width - 1) / width)

        let renderer = try MetalRenderer()
        let diffShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct SpringTrack {
            float4 abcd;
            float2 rates;
            float goal;
            uint kind;
            float2 start;
            float duration;
            float pad;
        };

        struct GPUQuery {
            SpringTrack track;
            float4 time;
        };

        inline float spring_exp(float x) {
            if (x < -87.0) return 0.0;
            float xc = clamp(x, -87.0, 88.0);
            float k = round(xc * 1.4426950408889634);
            float r = fma(-k, 0.0000014286068, fma(-k, 0.69314575, xc));
            float r2 = r * r;
            float a = 1.0 + r;
            float b = fma(r, 1.0 / 6.0, 0.5);
            float c = fma(r, 1.0 / 120.0, 1.0 / 24.0);
            float p = fma(r2, fma(r2, fma(r2, 1.0 / 720.0, c), b), a);
            return p * as_type<float>(uint(int(k) + 127) << 23u);
        }

        inline float2 spring_sample(SpringTrack s, float2 time) {
            float whole = float(int(time.x) - int(s.start.x));
            float t = max(whole + (time.y - s.start.y), 0.0);
            if (s.kind == 0u || t >= s.duration) return float2(s.goal, 0.0);
            float4 c = s.abcd;
            if (s.kind == 1u) {
                float e = exp(-s.rates.x * t);
                float co = cos(s.rates.y * t);
                float si = sin(s.rates.y * t);
                return float2(s.goal + e * (c.x * co + c.y * si), e * (c.z * co + c.w * si));
            }
            if (s.kind == 2u) {
                float e = exp(-s.rates.x * t);
                return float2(s.goal + (c.x + c.y * t) * e, (c.z + c.w * t) * e);
            }
            float e1 = spring_exp(c.z * t);
            float e2 = spring_exp(c.w * t);
            return float2(s.goal + (c.x * e1 + c.y * e2), c.x * c.z * e1 + c.y * c.w * e2);
        }

        struct DiffOut {
            float4 p [[position]];
            float4 result [[flat]];
        };

        vertex DiffOut diff_vs(
            device const GPUQuery *queries [[buffer(0)]],
            constant uint &height [[buffer(1)]],
            uint vi [[vertex_id]],
            uint iid [[instance_id]]
        ) {
            GPUQuery q = queries[iid];
            float2 val = spring_sample(q.track, q.time.xy);
            float x = float(iid % 256u) + float(vi & 1u);
            float y = float(iid / 256u) + float(vi >> 1u);
            DiffOut o;
            o.p = float4(x / 256.0 * 2.0 - 1.0, 1.0 - y / float(height) * 2.0, 0.0, 1.0);
            o.result = float4(val.x, val.y, clamp(val.x, 0.0, 1.0), 1.0);
            return o;
        }

        fragment float4 diff_fs(DiffOut in [[stage_in]]) {
            return in.result;
        }
        """

        let lib = try renderer.device.makeLibrary(source: diffShaderSource, options: nil)
        guard let vsFn = lib.makeFunction(name: "diff_vs"),
              let fsFn = lib.makeFunction(name: "diff_fs") else {
            throw NSError(domain: "RuneGpuSprings", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing differential shader entry points"])
        }
        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vsFn
        pipeDesc.fragmentFunction = fsFn
        pipeDesc.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try renderer.device.makeRenderPipelineState(descriptor: pipeDesc)

        let queryBytes = queries.count * MemoryLayout<GPUQuery>.stride
        guard let inputBuf = queries.withUnsafeBytes({ raw in
            renderer.device.makeBuffer(bytes: raw.baseAddress!, length: queryBytes, options: .storageModeShared)
        }) else {
            throw NSError(domain: "RuneGpuSprings", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate GPU differential input buffer"])
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget]
        texDesc.storageMode = .shared
        guard let outTex = renderer.device.makeTexture(descriptor: texDesc),
              let readBuf = renderer.device.makeBuffer(length: width * height * 16, options: .storageModeShared),
              let cb = renderer.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "RuneGpuSprings", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate differential render resources"])
        }

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = outTex
        rpDesc.colorAttachments[0].loadAction = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpDesc) {
            var hU32 = UInt32(height)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(inputBuf, offset: 0, index: 0)
            enc.setVertexBytes(&hU32, length: MemoryLayout<UInt32>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: queries.count)
            enc.endEncoding()
        }
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(
                from: outTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: readBuf,
                destinationOffset: 0,
                destinationBytesPerRow: width * 16,
                destinationBytesPerImage: width * height * 16
            )
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        let gpuPtr = readBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: queries.count)
        let samples = Array(UnsafeBufferPointer(start: gpuPtr, count: queries.count))
        #elseif os(Linux) || os(Windows)
        let samples = try sampleGLSpringTracks(tracks)
        #else
        let samples = tracks.map { item in
            let sampled = item.track.sample(at: item.now)
            return SIMD4(sampled.position, sampled.velocity, min(max(sampled.position, 0), 1), 1)
        }
        #endif

        for (idx, item) in tracks.enumerated() {
            let got = samples[idx]
            let err = abs(item.expectedPos - got.x)
            let limit: Float = item.opacity ? 0.0001 : 0.01
            if !got.x.isFinite || !got.y.isFinite || !got.z.isFinite || err > limit {
                failures += 1
            }
            let velocityError = abs(item.expectedVel - got.y)
            maxVelAbs = max(maxVelAbs, velocityError)
            maxVelRel = max(maxVelRel, velocityError / max(abs(item.expectedVel), 1.0))
            if item.opacity {
                let clamped = min(max(item.expectedPos, 0), 1)
                maxOpacity = max(maxOpacity, abs(clamped - got.z))
            } else {
                maxPosition = max(maxPosition, err)
            }
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
        #if canImport(Metal) || os(Linux) || os(Windows)
        guard counts.allSatisfy({ UInt32(exactly: $0) != nil }), runs >= 0, frames >= 0 else {
            throw NSError(domain: "RuneGpuSprings", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid spring benchmark dimensions"])
        }
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

        #endif

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
            let initialStore = store

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

            let cpuRenderer = try SpringFrameRenderer()
            #if !canImport(Metal)
            defer { cpuRenderer.close() }
            #endif
            let gpuRenderer = try SpringFrameRenderer()
            #if canImport(Metal)
            gpuRenderer.withSprings(nodes: nodes, ids: ids, timeSeconds: 0)
            #else
            defer { gpuRenderer.close() }
            if !nodes.isEmpty {
                try gpuRenderer.withSprings(nodes: nodes, ids: ids, timeSeconds: 0)
            }
            #endif

            var cpuRunMedians: [Double] = []
            var gpuRunMedians: [Double] = []
            for run in 0..<runs {
                for k in 0..<2 {
                    let path = (k + run) % 2
                    if path == 0 { store = initialStore }
                    var stepUs: [Double] = []
                    for f in 0..<frames {
                        let now = Double(f) / 120.0
                        let t0 = ContinuousClock.now
                        let frame: RenderFrame
                        let activeRenderer: SpringFrameRenderer
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
                        #if canImport(Metal)
                        if let cb = activeRenderer.commandQueue.makeCommandBuffer() {
                            activeRenderer.drawRange(frame: frame, into: targetTex, commandBuffer: cb)
                            cb.commit()
                            stepUs.append(us(t0.duration(to: .now)))
                            cb.waitUntilCompleted()
                        } else {
                            stepUs.append(us(t0.duration(to: .now)))
                        }
                        #else
                        let submittedAt = try activeRenderer.submitOffscreen(frame)
                        stepUs.append(us(t0.duration(to: submittedAt)))
                        #endif
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
                    // Match the vertex inputs' split time and exact settle deadline on the CPU.
                    let node = nodes[i]
                    let x = node.x.sample(at: now).position
                    let y = node.y.sample(at: now).position
                    let a = min(max(node.opacity.sample(at: now).position, 0), 1)
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
                #if canImport(Metal)
                gpuRenderer.updateSpringNode(index: 0, node: staticNode)
                #else
                try gpuRenderer.withSprings(nodes: [staticNode], ids: [0], timeSeconds: 0)
                #endif
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
        #if canImport(Metal) || os(Linux) || os(Windows)
        let cpu = try SpringFrameRenderer()
        #if !canImport(Metal)
        defer { cpu.close() }
        #endif
        let fast = try SpringFrameRenderer()
        #if !canImport(Metal)
        defer { fast.close() }
        #endif
        let s = Spring(duration: 0.4, bounce: 0.16)
        let fade = Spring(duration: 0.4, bounce: 0.0)
        let node = GPUSpringNode(
            x: GPUSpringTrack(spring: s, initial: 0, velocity: 0, goal: 6.0, startSeconds: 0, epsilon: 0.001),
            y: GPUSpringTrack(spring: s, initial: 0, velocity: 0, goal: 3.0, startSeconds: 0, epsilon: 0.001),
            opacity: GPUSpringTrack(spring: fade, initial: 0.2, velocity: 0, goal: 0.9, startSeconds: 0, epsilon: 0.00001)
        )
        #if canImport(Metal)
        fast.withSprings(nodes: [node], ids: Array(repeating: UInt32(0), count: 8), timeSeconds: 0)
        #else
        try fast.withSprings(nodes: [node], ids: Array(repeating: UInt32(0), count: 8), timeSeconds: 0)
        #endif

        var r8 = R8Atlas(width: 64, height: 64)
        r8.texels[0] = 255
        r8.texels[1] = 192
        r8.texels[64] = 128
        r8.texels[65] = 255

        let imageAtlas = RGBA8Atlas(
            width: 2,
            height: 2,
            texels: [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 192, 255, 255, 255, 255]
        )

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
            case 7:
                inst.uv = SIMD4<Float>(0.0, 0.0, 2.0, 2.0)
            default:
                break
            }
            return inst
        }

        var maxDelta: UInt8 = 0
        for now in [0.0, 0.07, 0.31, 0.99] {
            let dx = node.x.sample(at: now).position
            let dy = node.y.sample(at: now).position
            let alpha = min(max(node.opacity.sample(at: now).position, 0), 1)
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
            let cpuImg = try cpu.renderOffscreen(RenderFrame(width: 512, height: 96, clearColor: .zero, glyphs: r8, glyphGeneration: 1, images: imageAtlas, imageRevision: 1, instances: expected))
            fast.setSpringTime(now)
            let gpuImg = try fast.renderOffscreen(RenderFrame(width: 512, height: 96, clearColor: .zero, glyphs: r8, glyphGeneration: 1, images: imageAtlas, imageRevision: 1, instances: base))
            for kind in 0..<8 {
                let x0 = kind * 60
                let x1 = x0 + 60
                let hasAlpha = (0..<96).contains { y in
                    (x0..<x1).contains { x in
                        cpuImg.rgba[(y * 512 + x) * 4 + 3] != 0
                    }
                }
                precondition(hasAlpha, "blank primitive kind \(kind) at t=\(now)")
            }
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
        frames: Int = 120,
        verifyOnly: Bool = false
    ) throws -> (diff: DifferentialSummary, bench: [BenchSummary], primitives: (kindsChecked: Int, maxDelta: UInt8), output: String) {
        let diff = try runDifferential(iterations: diffIterations)
        let bench = verifyOnly ? [] : try runBench(counts: counts, runs: runs, frames: frames)
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
        let verifyOnly = CommandLine.arguments.contains("--verify-only")
        let (_, _, _, text) = try runReport(verifyOnly: verifyOnly)
        print(text)
    }
}
