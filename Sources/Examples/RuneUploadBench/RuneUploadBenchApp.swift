import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Metal)
import Metal
#endif

/// Parity port of `crates/rune/examples/upload_bench.rs`:
/// Headless per-frame GPU upload cost for 2,000 instances (`steady` vs `scroll`).
@main
public enum RuneUploadBenchApp {
    public static let size = (width: 1280, height: 800)
    public static let defaultCount = 2000
    public static let defaultFrames = 600
    public static let defaultWarmup = 60

    public struct SceneResult: Sendable, Equatable {
        public let scene: String
        public let cpuUs: Double
        public let kinstr: Double
        public let frameUs: Double
        public let encodeKinstr: Double
        public let submitKinstr: Double
    }

    public static func buildScene(frame: Int, scroll: Bool, count: Int = defaultCount) -> [RenderInstance] {
        (0..<count).map { i in
            var x = Float(i % 50) * 25.0
            var y = Float(i / 50) * 20.0
            if scroll {
                y -= Float(frame % 200)
            } else if i % 700 == 0 {
                x += Float(frame % 100)
            }
            return RenderInstance(
                rect: SIMD4<Float>(x, y, 20, 14),
                radii: SIMD4<Float>(3, 3, 3, 3),
                fill: SIMD4<Float>(0.2, 0.4, 0.8, 1.0),
                clip: NO_CLIP
            )
        }
    }

    private static func kinstr() -> Double {
        #if os(macOS)
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return rc == 0 ? Double(info.ri_instructions) / 1e3 : 0
        #else
        return 0
        #endif
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func us(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
    }

    public static func runReport(
        frames: Int = defaultFrames,
        warmup: Int = defaultWarmup,
        count: Int = defaultCount
    ) throws -> (results: [SceneResult], output: String) {
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        guard let targetTex = renderer.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "RuneUploadBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"])
        }

        var results: [SceneResult] = []
        var lines: [String] = []
        for (name, scroll) in [("steady", false), ("scroll", true)] {
            var cpu: [Double] = []
            var instructions: [Double] = []
            var frameTimes: [Double] = []
            var encodePhases: [Double] = []
            var submitPhases: [Double] = []

            for i in 0..<(frames + warmup) {
                let instances = buildScene(frame: i, scroll: scroll, count: count)
                let rf = RenderFrame(width: size.width, height: size.height, instances: instances)
                let t0 = ContinuousClock.now
                let k0 = kinstr()
                guard let cb = renderer.commandQueue.makeCommandBuffer() else { continue }
                renderer.drawRange(frame: rf, into: targetTex, commandBuffer: cb)
                let k1 = kinstr()
                cb.commit()
                let k2 = kinstr()
                let recordedUs = us(t0.duration(to: .now))
                let recordedK = k2 - k0
                cb.waitUntilCompleted()
                if i >= warmup {
                    cpu.append(recordedUs)
                    instructions.append(recordedK)
                    frameTimes.append(us(t0.duration(to: .now)))
                    encodePhases.append(k1 - k0)
                    submitPhases.append(k2 - k1)
                }
            }

            let res = SceneResult(
                scene: name,
                cpuUs: median(cpu),
                kinstr: median(instructions),
                frameUs: median(frameTimes),
                encodeKinstr: median(encodePhases),
                submitKinstr: median(submitPhases)
            )
            results.append(res)
            lines.append(String(
                format: "scene=%@ cpu_us=%.1f kinstr=%.1f frame_us=%.1f",
                res.scene, res.cpuUs, res.kinstr, res.frameUs
            ))
            lines.append(String(
                format: "  phases kinstr: encode=%.1f submit=%.1f",
                res.encodeKinstr, res.submitKinstr
            ))
        }
        return (results, lines.joined(separator: "\n"))
        #else
        return ([], "upload_bench: Metal unavailable on this platform")
        #endif
    }

    public static func main() throws {
        let envFrames = ProcessInfo.processInfo.environment["UPLOAD_FRAMES"].flatMap(Int.init)
        let (_, output) = try runReport(frames: envFrames ?? defaultFrames)
        print(output)
    }
}
