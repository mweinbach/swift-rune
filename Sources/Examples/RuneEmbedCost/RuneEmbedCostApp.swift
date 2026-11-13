import Foundation
import Rune
import RuneKit
import RuneMotion
import RuneRef

#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore
#endif

#if canImport(Darwin)
import Darwin
#endif

/// Port of upstream `crates/rune/examples/embed_cost.rs`.
@main
public enum RuneEmbedCostApp {
    public struct State: Sendable {
        public var tick: Int = 0
        public var paragraphs: [String]
        public init(paragraphs: Int = 18) {
            self.paragraphs = (0..<paragraphs).map { i in
                "Paragraph \(i): Embedded LayerHost cost harness measuring first frame, layout reuse, glyph atlas, and resident footprint across scrollable blocks."
            }
        }
    }

    public struct Report: Sendable {
        public let hostMs: Double
        public let firstFrameMs: Double
        public let frames: Int
        public let drew: Int
        public let fps: Double
        public let mainCpuUsPerFrame: Double
        public let footprintMB: Double
        public let output: String
    }

    private static func residentMB() -> Double {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Double(info.phys_footprint) / 1_048_576.0
        }
        #endif
        return 0
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let style = MarkdownStyle.fromKit(Kit.neutral(dark: true))
        let body = s.paragraphs.enumerated().map { idx, line in
            col()
                .key("p-\(idx)")
                .wFull()
                .p(10)
                .rounded(8)
                .bg(Color.white.alpha(idx % 2 == 0 ? 0.05 : 0.03))
                .child(MarkdownView<State>("### Block \(idx)\n\n\(line)").render(style))
        }
        return col()
            .wFull()
            .hFull()
            .bg(Color.rgba8(0x0b, 0x0b, 0x0c))
            .child(
                col()
                    .key("embed-scroll")
                    .wFull()
                    .grow(1)
                    .minH(0)
                    .scroll(stickBottom: false)
                    .p(14)
                    .gap(8)
                    .children(body)
            )
    }

    public static func makeSpec() -> AppSpec<State> {
        AppSpec(
            title: "embed_cost",
            size: Vec2(430, 932),
            state: State(),
            view: view
        )
    }

    public static func runReport(
        warmup: Int = 8,
        frames: Int = 30,
        useLiveLayer: Bool = false
    ) throws -> Report {
        let began = ContinuousClock.now
        let config = EmbedHostConfig(transparentBackground: false, forwardScrollEvents: true, initialSize: Vec2(430, 932))
        let spec = makeSpec()
        #if canImport(Metal) && canImport(QuartzCore)
        let host: LayerHost<State>
        if useLiveLayer {
            host = try LayerHost(layer: CAMetalLayer(), spec: spec, scale: 2.0, dark: true, config: config)
        } else {
            host = try LayerHost(layer: nil, spec: spec, scale: 2.0, dark: true, config: config)
        }
        #else
        let host = LayerHost(spec: spec, scale: 2.0, dark: true, config: config)
        #endif
        let hostDur = began.duration(to: .now)
        let hostMs = Double(hostDur.components.seconds) * 1e3 + Double(hostDur.components.attoseconds) / 1e15

        var now = 0.0
        _ = host.frame(at: now)
        let firstDur = began.duration(to: .now)
        let firstMs = Double(firstDur.components.seconds) * 1e3 + Double(firstDur.components.attoseconds) / 1e15

        for _ in 0..<warmup {
            now += 1.0 / 120.0
            _ = host.frame(at: now)
        }

        let cpu0 = threadCpuMs()
        let wall0 = ContinuousClock.now
        var drew = 0
        for i in 0..<frames {
            now += 1.0 / 120.0
            if i % 5 == 0 {
                host.update { st, _ in st.tick += 1 }
            }
            if host.frame(at: now).drew {
                drew += 1
            }
        }
        let cpuMs = max(0, threadCpuMs() - cpu0)
        let wallDur = wall0.duration(to: .now)
        let wallSecs = max(1e-6, Double(wallDur.components.seconds) + Double(wallDur.components.attoseconds) / 1e18)
        let n = Double(max(1, frames))
        let fps = n / wallSecs
        let mainUs = (cpuMs * 1e3) / n
        let footprint = residentMB()

        let out = [
            String(format: "backend=%@ host_ms=%.1f first_frame_ms=%.1f frames=%d drew=%d fps=%.1f",
                   useLiveLayer ? "metal" : "headless", hostMs, firstMs, frames, drew, fps),
            String(format: "per_frame: main_cpu_us=%.1f", mainUs),
            String(format: "footprint_mb: steady=%.1f", footprint),
        ].joined(separator: "\n")

        return Report(
            hostMs: hostMs,
            firstFrameMs: firstMs,
            frames: frames,
            drew: drew,
            fps: fps,
            mainCpuUsPerFrame: mainUs,
            footprintMB: footprint,
            output: out
        )
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let frames = Int(ProcessInfo.processInfo.environment["EMBED_FRAMES"] ?? "") ?? (args.contains("--bench") ? 600 : 120)
        let warmup = Int(ProcessInfo.processInfo.environment["EMBED_WARMUP"] ?? "") ?? 30
        let useLayer = !args.contains("--no-layer")
        do {
            let report = try runReport(warmup: warmup, frames: frames, useLiveLayer: useLayer)
            print(report.output)
        } catch {
            fputs("embed_cost error: \(error)\n", stderr)
            exit(1)
        }
    }
}
