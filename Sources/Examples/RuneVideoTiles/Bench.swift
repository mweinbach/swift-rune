import Foundation
import Metal
import Rune

public struct NativeBenchRunStats: Sendable, Codable {
    public let cpuP50Ms: Double
    public let cpuP95Ms: Double
    public let gpuSamples: Int
    public let gpuP50Ms: Double?
    public let gpuP95Ms: Double?

    enum CodingKeys: String, CodingKey {
        case cpuP50Ms = "cpu_p50_ms"
        case cpuP95Ms = "cpu_p95_ms"
        case gpuSamples = "gpu_samples"
        case gpuP50Ms = "gpu_p50_ms"
        case gpuP95Ms = "gpu_p95_ms"
    }
}

public struct NativeBenchProfileResult: Sendable, Codable {
    public let tiles: Int
    public let source: [UInt32]
    public let target: [UInt32]
    public let hz: Int
    public let warmupRuns: Int
    public let runs: [NativeBenchRunStats]
    public let cpuMedianMs: Double?
    public let gpuMedianMs: Double?
    public let cpuPerTileMs: Double?
    public let gpuPerTileMs: Double?

    enum CodingKeys: String, CodingKey {
        case tiles
        case source
        case target
        case hz
        case warmupRuns = "warmup_runs"
        case runs
        case cpuMedianMs = "cpu_median_ms"
        case gpuMedianMs = "gpu_median_ms"
        case cpuPerTileMs = "cpu_per_tile_ms"
        case gpuPerTileMs = "gpu_per_tile_ms"
    }
}

public struct NativeBenchResult: Sendable {
    public let profiles: [NativeBenchProfileResult]
    public let totalFrames: Int
    public let elapsedSeconds: Double
    public let fps: Double
}

private final class BenchTimingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []

    func append(_ ms: Double) {
        lock.lock()
        samples.append(ms)
        lock.unlock()
    }

    func drain() -> [Double] {
        lock.lock()
        let out = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }
}

public enum VideoTilesBench {
    public static let upstreamProfiles: [(tiles: Int, width: UInt32, height: UInt32)] = [
        (1, 1920, 1080),
        (4, 1920, 1080),
        (9, 1920, 1080),
        (1, 3840, 2160),
        (1, 5120, 2880),
    ]

    public static func median(_ values: [Double]) -> Double? {
        percentile(values, p: 0.5)
    }

    public static func percentile(_ values: [Double], p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return sorted[idx]
    }

    public static func runNativeBench(
        profiles: [(tiles: Int, width: UInt32, height: UInt32)] = upstreamProfiles,
        runs runCount: Int = 8,
        framesPerRun: Int = 30,
        pace60Hz: Bool = true
    ) throws -> NativeBenchResult {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw NSError(
                domain: "RuneVideoTiles",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"]
            )
        }

        let overallStart = ContinuousClock.now
        var profileResults: [NativeBenchProfileResult] = []
        var totalFrames = 0

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (tiles, w, h) in profiles {
            let columns = max(1, UInt32(Double(tiles).squareRoot()))
            let outW = w * columns
            let outH = h * columns

            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: Int(outW),
                height: Int(outH),
                mipmapped: false
            )
            texDesc.usage = [.renderTarget, .shaderRead]
            texDesc.storageMode = .private
            guard let targetTex = device.makeTexture(descriptor: texDesc) else {
                throw NSError(
                    domain: "RuneVideoTiles",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to allocate render target"]
                )
            }

            let renderer = try SurfaceRenderer(device: device, pixelFormat: .bgra8Unorm_srgb)
            let surfaces = (0..<tiles).map { _ in NativeSurface() }
            let timingsBox = BenchTimingsBox()
            let completionSem = DispatchSemaphore(value: 0)

            surfaces[0].setObserver { timing in
                if let start = timing.gpuStartSeconds, let end = timing.gpuEndSeconds, end >= start {
                    timingsBox.append((end - start) * 1000.0)
                }
                if timing.completedAt != nil {
                    completionSem.signal()
                }
            }

            let fullClip = SIMD4<Float>(0, 0, Float(outW), Float(outH))
            let draws: [SurfaceDraw] = surfaces.enumerated().map { idx, surface in
                let col = UInt32(idx) % columns
                let row = UInt32(idx) / columns
                return SurfaceDraw(
                    surface: surface,
                    fit: .fit,
                    beforeInstance: 0,
                    rect: SIMD4<Float>(Float(col * w), Float(row * h), Float(w), Float(h)),
                    clip: fullClip
                )
            }

            // Three independent recyclable buffers per tile pre-allocated before timing.
            #if os(macOS)
            let bufferPool: [[CoreVideoPixelBuffer]] = try (0..<tiles).map { _ in
                try (0..<3).map { bufIdx in
                    let frame = ByteFrame.synthetic(width: w, height: h, index: UInt64(bufIdx))
                    return try CoreVideoPixelBuffer.fromBytes(frame)
                }
            }
            #else
            let bufferPool: [[ByteFrame]] = (0..<tiles).map { _ in
                (0..<3).map { bufIdx in
                    ByteFrame.synthetic(width: w, height: h, index: UInt64(bufIdx))
                }
            }
            #endif

            var measuredRuns: [NativeBenchRunStats] = []
            let totalRuns = max(1, runCount)
            let frames = max(1, framesPerRun)

            for run in 0..<totalRuns {
                _ = timingsBox.drain()
                var cpuMs: [Double] = []
                cpuMs.reserveCapacity(frames)

                for frame in 0..<frames {
                    let begin = ContinuousClock.now
                    let frameId = UInt64(run * frames + frame + 1)
                    for i in 0..<surfaces.count {
                        #if os(macOS)
                        try surfaces[i].push(bufferPool[i][frame % 3], frameId: frameId)
                        #else
                        try surfaces[i].pushBytes(bufferPool[i][frame % 3], frameId: frameId)
                        #endif
                    }

                    renderer.prepare(draws: draws, viewport: (outW, outH))
                    guard let cmd = queue.makeCommandBuffer() else { continue }
                    let passDesc = MTLRenderPassDescriptor()
                    passDesc.colorAttachments[0].texture = targetTex
                    passDesc.colorAttachments[0].loadAction = .clear
                    passDesc.colorAttachments[0].storeAction = .store
                    passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

                    if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
                        for idx in 0..<surfaces.count {
                            renderer.draw(encoder: enc, index: idx)
                        }
                        enc.endEncoding()
                    }
                    renderer.trackSubmission(commandBuffer: cmd)
                    cmd.commit()

                    let elapsedDur = ContinuousClock.now - begin
                    let elapsedMs = Double(elapsedDur.components.seconds) * 1000.0
                        + Double(elapsedDur.components.attoseconds) / 1e15
                    cpuMs.append(elapsedMs)

                    _ = completionSem.wait(timeout: .now() + .seconds(10))
                    if pace60Hz {
                        let paceTargetMs = 1000.0 / 60.0
                        if elapsedMs < paceTargetMs {
                            Thread.sleep(forTimeInterval: (paceTargetMs - elapsedMs) / 1000.0)
                        }
                    }
                    totalFrames += 1
                }

                let gpuSnapshot = timingsBox.drain()

                if run > 0 || totalRuns == 1 {
                    measuredRuns.append(
                        NativeBenchRunStats(
                            cpuP50Ms: median(cpuMs) ?? 0.0,
                            cpuP95Ms: percentile(cpuMs, p: 0.95) ?? 0.0,
                            gpuSamples: gpuSnapshot.count,
                            gpuP50Ms: median(gpuSnapshot),
                            gpuP95Ms: percentile(gpuSnapshot, p: 0.95)
                        )
                    )
                }
            }

            let cpuMedians = measuredRuns.map(\.cpuP50Ms)
            let gpuMedians = measuredRuns.compactMap(\.gpuP50Ms)
            let cpuMedian = median(cpuMedians)
            let gpuMedian = median(gpuMedians)
            let profileResult = NativeBenchProfileResult(
                tiles: tiles,
                source: [w, h],
                target: [outW, outH],
                hz: 60,
                warmupRuns: totalRuns > 1 ? 1 : 0,
                runs: measuredRuns,
                cpuMedianMs: cpuMedian,
                gpuMedianMs: gpuMedian,
                cpuPerTileMs: cpuMedian.map { $0 / Double(tiles) },
                gpuPerTileMs: gpuMedian.map { $0 / Double(tiles) }
            )
            profileResults.append(profileResult)

            if let jsonData = try? encoder.encode(profileResult),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        }

        let totalDur = ContinuousClock.now - overallStart
        let elapsedSeconds = max(
            1e-6,
            Double(totalDur.components.seconds) + Double(totalDur.components.attoseconds) / 1e18
        )
        return NativeBenchResult(
            profiles: profileResults,
            totalFrames: totalFrames,
            elapsedSeconds: elapsedSeconds,
            fps: Double(totalFrames) / elapsedSeconds
        )
    }
}
