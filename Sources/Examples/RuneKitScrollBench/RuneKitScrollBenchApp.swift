import Foundation
import Rune
import RuneKit
#if canImport(Darwin)
import Darwin
#endif

/// Parity port of `crates/rune-kit/examples/scroll_bench.rs`:
/// Benchmarks deterministic scroll workloads (`list`, `markdown`, `sticky`, `growth`, `prose`, `card`)
/// across 12 per-frame metrics (`p50`, `p95`, `mean`) and emits `METRIC` lines + `rune-scroll-profile` JSON.
@main
public enum RuneKitScrollBenchApp {
    public static let allWorkloads = ["list", "markdown", "sticky", "growth", "prose", "card"]
    public static let defaultSize = Vec2(760, 800)
    public static let prose =
        "Amber lantern orchard quiet harbor, copper meadow signal drift. Pebble willow " +
        "ember tide under a juniper kestrel; nimbus opal prism and a quiet harbor beneath the lantern. "

    public final class ViewCounter: @unchecked Sendable {
        private let lock = NSLock()
        public var builds: Int {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _builds
            }
            set {
                lock.lock()
                _builds = newValue
                lock.unlock()
            }
        }
        private var _builds: Int = 0

        public func increment() {
            lock.lock()
            _builds += 1
            lock.unlock()
        }
    }

    public struct State: @unchecked Sendable {
        public var workload: String
        public var rows: Int
        public var source: String
        public var notes: [String]
        public var marker: Int
        public var style: MarkdownStyle
        public let views = ViewCounter()

        public init(workload: String, rows: Int = 1000) {
            self.workload = workload
            self.rows = rows
            self.style = MarkdownStyle.neutral(dark: true)
            var md = ""
            for i in 0..<80 {
                md += "## Section \(i)\n\n"
                md += "\(prose)\(prose)\n\n- First **bold** item\n- Second `inline` item\n\n"
            }
            self.source = md
            self.notes = (0..<60).map { i in
                "### Note \(i)\n\n\(prose)\n\n`tag-\(i)` **ready**"
            }
            self.marker = 0
        }
    }

    // Compatibility type retained for Tests/RuneExamplesTests/ContentExamplesParityTests.swift.
    public struct BenchResult: Sendable, Equatable {
        public let workload: String
        public let frames: Int
        public let viewRebuilds: Int
        public let medianCpuMs: Double
        public let instances: Int
    }

    private struct FrameSample {
        let cpuMs: Double
        let viewCpuMs: Double
        let commitCpuMs: Double
        let layoutCpuMs: Double
        let textCpuMs: Double
        let paintCpuMs: Double
        let applyCpuMs: Double
        let commits: Double
        let viewRebuilds: Double
        let instances: Double
        let allocations: Double
        let shaped: Double
    }

    private static func liveBlocks() -> Int64 {
        #if canImport(Darwin)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int64(stats.blocks_in_use)
        #else
        return 0
        #endif
    }

    private static func itemRow(_ i: Int) -> El<State> {
        col()
            .key("row-\(i)")
            .wFull()
            .h(32)
            .hover(Color.white.alpha(0.08))
            .onClick { _ in }
            .child(
                text("Row \(i): amber lantern orchard quiet harbor")
                    .font(TextStyle(size: 14, weight: 400))
                    .color(.white)
            )
    }

    private static func chip(_ label: String, _ i: Int, _ c: Int) -> El<State> {
        row()
            .key("chip-\(i)-\(c)")
            .h(20)
            .px(6)
            .gap(4)
            .itemsCenter()
            .rounded(5)
            .bg(Color.white.alpha(0.08))
            .hover(Color.white.alpha(0.14))
            .onClick { _ in }
            .child(el().size(8, 8).rounded(4).bg(oklch(0.72, 0.12, 245)))
            .child(text(label).font(TextStyle(size: 12, weight: 500)).color(.white))
    }

    private static func entryCard(_ s: State, _ i: Int, _ note: String) -> El<State> {
        let small = TextStyle(size: 12, weight: 400)
        let head = row()
            .key("head")
            .wFull()
            .gap(8)
            .itemsCenter()
            .child(el().size(22, 22).rounded(11).bg(oklch(0.6, 0.14, 295)))
            .child(text("Agent \(i % 7)").font(TextStyle(size: 13, weight: 600)).color(.white))
            .child(text("\(3 + i)m ago").font(small).color(Color.white.alpha(0.5)))
            .child(row().key("chips").gap(4).children((0..<3).map { c in chip("t\(400 + i * 3 + c)", i, c) }))
        let links: El<State> = row()
            .key("links")
            .wFull()
            .gap(6)
            .flexWrap()
            .children((0..<4).map { c in
                text("#\(1000 + i) lantern-\(c)")
                    .key("link-\(c)")
                    .font(small)
                    .color(oklch(0.75, 0.1, 250))
                    .onClick { _ in }
            })
        let fillAlpha: Float = (i == s.marker) ? 0.07 : 0.04
        return col()
            .key("entry-\(i)")
            .wFull()
            .gap(6)
            .p(10)
            .rounded(8)
            .bg(Color.white.alpha(fillAlpha))
            .border(1, Color.white.alpha(0.08))
            .onDrawnLayoutTx { _, _, tx in
                tx.liveOnly()
            }
            .child(head)
            .child(MarkdownView<State>(note).render(s.style).key("note"))
            .child(links)
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        s.views.increment()
        let content: El<State>
        switch s.workload {
        case "markdown":
            content = MarkdownView<State>(s.source).render(s.style)
        case "sticky":
            content = col().wFull().children((0..<40).map { section in
                col().key("section-\(section)").wFull()
                    .child(
                        text("Section \(section)")
                            .key("header")
                            .h(32)
                            .wFull()
                            .bg(.black)
                            .color(.white)
                            .stickyTop(0)
                    )
                    .children((0..<20).map { i in itemRow(section * 20 + i) })
            })
        case "growth":
            content = col().key("stack").wFull().growth(.default).children((0..<s.rows).map(itemRow))
        case "list":
            content = col().wFull().children((0..<s.rows).map(itemRow))
        case "prose":
            content = col().wFull().gap(12).p(16).children((0..<200).map { i -> El<State> in
                let repeated = String(repeating: prose, count: 1 + i % 3)
                return text("\(i). \(repeated)")
                    .key("para-\(i)")
                    .font(TextStyle(size: 13, weight: 400))
                    .color(.white)
                    .wFull()
            })
        case "card":
            content = col()
                .wFull()
                .gap(14)
                .p(16)
                .hoverMotionWithin(.instant, .instant)
                .children(s.notes.enumerated().map { entryCard(s, $0.offset, $0.element) })
        default:
            fatalError("Unknown scroll_bench workload: \(s.workload)")
        }

        return col().wFull().hFull().bg(.black).child(
            col()
                .key("viewport")
                .wFull()
                .hFull()
                .scroll(stickBottom: s.workload == "growth")
                .clipFade(top: 12, bottom: 12)
                .child(content)
        )
    }

    private static func stats(_ values: [Double]) -> (p50: Double, p95: Double, mean: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let sorted = values.sorted()
        let n = sorted.count
        let p50: Double = n % 2 == 1
            ? sorted[n / 2]
            : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        let p95Idx = min(n - 1, Int(Double(n - 1) * 0.95))
        let mean = values.reduce(0, +) / Double(n)
        return (p50, sorted[p95Idx], mean)
    }

    public static func runParityWorkload(
        _ workload: String,
        frames: Int,
        fps: Double,
        size: Vec2
    ) -> [String] {
        let rt = Runtime(
            state: State(workload: workload, rows: 1000),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        let pointerPos = Vec2(size.x * 0.5, size.y * 0.5)
        var now = 0.0
        _ = rt.frame(at: now)
        rt.pointerMove(to: pointerPos, at: now)
        let dt = 1.0 / fps
        for _ in 0..<120 {
            now += dt
            _ = rt.frame(at: now)
        }
        FileHandle.standardError.write(Data("scroll-bench elements \(rt.elements().count)\n".utf8))

        var samples: [FrameSample] = []
        samples.reserveCapacity(frames)

        for i in 0..<frames {
            now += dt
            let direction: Float = ((i < frames / 2) != (workload == "growth")) ? -1.0 : 1.0
            let dy = direction * 12.0
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: pointerPos, now: now)

            if workload == "growth" && i % 12 == 0 {
                rt.state.rows += 1
                rt.invalidate()
            } else if workload == "card" {
                rt.state.marker = (rt.state.marker + 1) % max(1, rt.state.notes.count)
                rt.invalidate()
            }

            _ = takeFramePhases()
            let commitsBefore = rt.viewCommitCount
            let viewsBefore = rt.state.views.builds
            let blocksBefore = liveBlocks()
            let c0 = threadCpuMs()
            let scene = rt.frame(at: now)
            let cpuMs = max(0, threadCpuMs() - c0)
            let blocksAfter = liveBlocks()
            let phases = takeFramePhases()

            func phase(_ idx: Int) -> Double {
                phases.count > idx ? phases[idx] : 0.0
            }

            samples.append(FrameSample(
                cpuMs: cpuMs,
                viewCpuMs: phase(6),
                commitCpuMs: phase(7),
                layoutCpuMs: phase(8),
                textCpuMs: phase(9),
                paintCpuMs: phase(10),
                applyCpuMs: phase(11),
                commits: Double(rt.viewCommitCount - commitsBefore),
                viewRebuilds: Double(rt.state.views.builds - viewsBefore),
                instances: Double(scene.primitives.count),
                allocations: Double(max(0, blocksAfter - blocksBefore)),
                shaped: 0.0
            ))
        }

        let metricDefs: [(String, (FrameSample) -> Double)] = [
            ("cpu_ms", { $0.cpuMs }),
            ("view_cpu_ms", { $0.viewCpuMs }),
            ("commit_cpu_ms", { $0.commitCpuMs }),
            ("layout_cpu_ms", { $0.layoutCpuMs }),
            ("text_cpu_ms", { $0.textCpuMs }),
            ("paint_cpu_ms", { $0.paintCpuMs }),
            ("apply_cpu_ms", { $0.applyCpuMs }),
            ("commits", { $0.commits }),
            ("view_rebuilds", { $0.viewRebuilds }),
            ("instances", { $0.instances }),
            ("allocations", { $0.allocations }),
            ("shaped", { $0.shaped }),
        ]

        var lines: [String] = []
        var jsonMetrics: [String: [String: Double]] = [:]
        for (name, extract) in metricDefs {
            let s = stats(samples.map(extract))
            lines.append(String(format: "METRIC %@_p50=%.9f", name, s.p50))
            lines.append(String(format: "METRIC %@_p95=%.9f", name, s.p95))
            lines.append(String(format: "METRIC %@_mean=%.9f", name, s.mean))
            jsonMetrics[name] = ["p50": s.p50, "p95": s.p95, "mean": s.mean]
        }

        let payload: [String: Any] = [
            "workload": workload,
            "frames": frames,
            "fps": fps,
            "width": Int(size.x),
            "height": Int(size.y),
            "metrics": jsonMetrics,
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            lines.append("rune-scroll-profile \(jsonStr)")
        }

        return lines
    }

    // Compatibility shims retained for Tests/RuneExamplesTests/ContentExamplesParityTests.swift.
    public static func runWorkload(
        _ workload: String,
        rows: Int = 200,
        frames: Int = 24,
        fps: Double = 120.0
    ) -> BenchResult {
        let rt = Runtime(
            state: State(workload: workload, rows: rows),
            viewport: defaultSize,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var now = 0.0
        _ = rt.frame(at: now)
        let builds0 = rt.state.views.builds
        var cpus: [Double] = []
        var lastInstances = 0
        for i in 0..<frames {
            let dy: Float = (i < frames / 2) ? -48.0 : 48.0
            now += 1.0 / fps
            let c0 = threadCpuMs()
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(defaultSize.x / 2, defaultSize.y / 2), now: now)
            let sc = rt.frame(at: now)
            cpus.append(max(0, threadCpuMs() - c0))
            lastInstances = sc.primitives.count
        }
        let med = stats(cpus).p50
        return BenchResult(
            workload: workload,
            frames: frames,
            viewRebuilds: rt.state.views.builds - builds0,
            medianCpuMs: med,
            instances: lastInstances
        )
    }

    public static func runAll(
        workloads: [String] = allWorkloads,
        rows: Int = 120,
        frames: Int = 16
    ) -> (results: [BenchResult], output: String) {
        let res = workloads.map { runWorkload($0, rows: rows, frames: frames) }
        let out = res.map {
            String(
                format: "WORKLOAD name=%@ frames=%d rebuilds=%d median_cpu_ms=%.4f instances=%d",
                $0.workload, $0.frames, $0.viewRebuilds, $0.medianCpuMs, $0.instances
            )
        }.joined(separator: "\n")
        return (res, out)
    }

    private struct CliArgs {
        var workload: String? = nil
        var frames: Int = 480
        var fps: Double = 120.0
        var size: Vec2 = defaultSize
    }

    private static func parseSize(_ raw: String) -> Vec2? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Float(parts[0]),
              let h = Float(parts[1]),
              w > 0, h > 0 else {
            return nil
        }
        return Vec2(w, h)
    }

    private static func parseArgs(_ args: [String]) -> CliArgs {
        var parsed = CliArgs()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--workload":
                i += 1
                if i < args.count { parsed.workload = args[i] }
            case "--frames":
                i += 1
                if i < args.count, let v = Int(args[i]), v > 0 { parsed.frames = v }
            case "--fps":
                i += 1
                if i < args.count, let v = Double(args[i]), v > 0 { parsed.fps = v }
            case "--size":
                i += 1
                if i < args.count, let s = parseSize(args[i]) { parsed.size = s }
            default:
                break
            }
            i += 1
        }
        return parsed
    }

    public static func main() {
        let cli = parseArgs(Array(CommandLine.arguments.dropFirst()))
        let workloads = cli.workload.map { [$0] } ?? allWorkloads
        FileHandle.standardError.write(Data(
            "scroll_bench note: TextSystem.shaped is not exposed by Rune (reporting 0.0); allocations reports Darwin malloc_zone_statistics live block deltas.\n".utf8
        ))
        var allLines: [String] = []
        for workload in workloads {
            if workloads.count > 1 {
                allLines.append("WORKLOAD \(workload)")
            }
            allLines.append(contentsOf: runParityWorkload(workload, frames: cli.frames, fps: cli.fps, size: cli.size))
        }
        print(allLines.joined(separator: "\n"))
    }
}
