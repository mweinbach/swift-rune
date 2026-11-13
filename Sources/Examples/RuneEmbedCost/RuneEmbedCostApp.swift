import Foundation
import Rune
import RuneKit
#if canImport(Darwin)
import Darwin
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

/// Headless / live embed cost benchmark mirroring `crates/rune/examples/embed_cost.rs`.
@main
public enum RuneEmbedCostApp {
    public struct State: Sendable {
        public var tick: UInt64 = 0
        public var scrollPhase: Float = 0
        public init() {}
    }

    public struct Report: Sendable {
        public let frames: Int
        public let drew: Int
        public let fps: Double
        public let output: String
    }

    public static func spec() -> AppSpec<State> {
        App(
            "Embed Cost",
            size: Vec2(800, 600),
            init: { State() },
            view: { _, _ in
                var sections: [El<State>] = []
                sections.reserveCapacity(60)
                for sec in 0..<60 {
                    var rows: [El<State>] = [
                        text("Section \(sec)")
                            .font(Tok.Typography.title)
                            .color(Color(r: 0.75, g: 0.78, b: 0.85, a: 1.0))
                    ]
                    rows.reserveCapacity(7)
                    for r in 0..<6 {
                        let hue = Float((sec * 23 + r * 37) % 360)
                        rows.append(
                            row()
                                .wFull()
                                .h(36.0)
                                .centerY()
                                .px(12.0)
                                .gap(10.0)
                                .bg(Color(r: 0.14, g: 0.16, b: 0.20, a: 1.0))
                                .rounded(8.0)
                                .border(1.0, Color(r: 0.24, g: 0.26, b: 0.32, a: 1.0))
                                .children([
                                    el()
                                        .size(20.0, 20.0)
                                        .rounded(10.0)
                                        .bg(oklch(0.68, 0.14, hue)),
                                    text("Row \(sec).\(r) — scrolling embed cost benchmark")
                                        .font(Tok.Typography.body)
                                        .color(Color(r: 0.92, g: 0.93, b: 0.96, a: 1.0)),
                                    el().grow(1.0),
                                ])
                        )
                    }
                    sections.append(
                        col()
                            .key("sec-\(sec)")
                            .wFull()
                            .gap(6.0)
                            .pb(12.0)
                            .children(rows)
                    )
                }
                return col()
                    .wFull()
                    .hFull()
                    .bg(Color(r: 0.08, g: 0.09, b: 0.11, a: 1.0))
                    .key("sections")
                    .scroll(ScrollSpec.default)
                    .children(sections)
            }
        )
        .poll { s, dt, tx in
            s.tick &+= 1
            s.scrollPhase += Float(dt) * 0.5
            let maxY: Float = 2400.0
            let targetY = (sin(Float(s.tick) * 0.08) * 0.5 + 0.5) * maxY
            tx.scrollToY("sections", targetY)
            return true
        }
        .intoSpec()
    }

    @MainActor
    public static func main() throws {
        if CommandLine.arguments.count > 1 {
            try RuneApp.run(spec())
            return
        }

        let warmup = Int(ProcessInfo.processInfo.environment["EMBED_WARMUP"] ?? "") ?? 120
        let frames = Int(ProcessInfo.processInfo.environment["EMBED_FRAMES"] ?? "") ?? 600
        let report = try runReport(warmup: warmup, frames: frames, useLiveLayer: true)
        print(report.output)
    }

    public static func runReport(
        warmup: Int = 8,
        frames: Int = 30,
        useLiveLayer: Bool = false
    ) throws -> Report {
        let appSpec = spec()
        let host: LayerHost<State>
        #if os(macOS) && canImport(Metal) && canImport(QuartzCore)
        if useLiveLayer {
            host = try LayerHost(layer: CAMetalLayer(), spec: appSpec, scale: 3.0, dark: true)
        } else {
            host = try LayerHost(spec: appSpec, scale: 3.0, dark: true)
        }
        #else
        host = try LayerHost(spec: appSpec, scale: 3.0, dark: true)
        #endif

        // LayerHost.init does not copy spec.poll onto runtime; wire it explicitly so oscillating scroll runs.
        host.runtime.poll = appSpec.poll

        for _ in 0..<8 {
            if host.frame(at: 0.0).drew {
                break
            }
        }
        let firstMB = Double(physFootprintBytes() ?? 0) / (1024.0 * 1024.0)

        var elapsed = 0.0
        for _ in 0..<max(0, warmup) {
            elapsed += 1.0 / 120.0
            _ = host.runtime.runPoll(at: elapsed)
            _ = host.frame(at: elapsed)
        }

        var peakBytes = physFootprintBytes() ?? 0
        let t0 = ContinuousClock.now
        let cpu0 = processCpuUs()
        let instr0 = processKinstructions()
        var drew = 0
        let frameCount = max(1, frames)
        for _ in 0..<frameCount {
            elapsed += 1.0 / 120.0
            _ = host.runtime.runPoll(at: elapsed)
            let out = host.frame(at: elapsed)
            if out.drew { drew += 1 }
            if let cur = physFootprintBytes(), cur > peakBytes {
                peakBytes = cur
            }
        }
        let wallMs = durationMs(t0.duration(to: .now))
        let cpuUs = processCpuUs() &- cpu0
        let kinstr = processKinstructions() &- instr0
        let peakMB = Double(peakBytes) / (1024.0 * 1024.0)
        let backend = ProcessInfo.processInfo.environment["RUNE_GPU_BACKEND"] ?? "default"

        let avgCpu = cpuUs / UInt64(frameCount)
        let fps = wallMs > 0 ? (Double(frameCount) * 1000.0 / wallMs) : 0.0
        let line = String(
            format: "embed_cost: backend=%@ frames=%d wall=%.1fms avg_cpu=%lluµs kinstr=%llu first_frame_mb=%.1f peak_mb=%.1f",
            backend,
            frameCount,
            wallMs,
            avgCpu,
            kinstr,
            firstMB,
            peakMB
        )
        return Report(frames: frameCount, drew: drew, fps: fps, output: line)
    }

    private static func durationMs(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1e15
    }

    private static func processCpuUs() -> UInt64 {
        #if canImport(Darwin)
        var ts = timespec()
        if clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0 {
            return UInt64(ts.tv_sec) * 1_000_000 &+ UInt64(ts.tv_nsec / 1000)
        }
        #endif
        return 0
    }

    private static func processKinstructions() -> UInt64 {
        #if canImport(Darwin) && os(macOS)
        var info = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        if rc == 0 {
            return info.ri_instructions / 1000
        }
        #endif
        return 0
    }

    private static func physFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return UInt64(info.phys_footprint)
        }
        #endif
        return nil
    }
}
