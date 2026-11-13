import Foundation
import Rune
import RunePerf

/// Parity port of `crates/rune/examples/interaction_cost.rs`:
/// Headless interaction timing & allocation bench (`press`, `wheel`, `idle`) under `RUNE_PERF`.
@main
public enum RuneInteractionCostApp {
    public static let size = Vec2(800, 600)
    public static let rowsCount = 300
    public static let defaultFrames = 120
    public static let defaultSamples = 9
    public static let scenarios = ["press", "wheel", "idle"]
    public static let metrics = ["p50_ms", "mean_ms", "allocations"]

    public struct Page: Sendable {
        public var rows: Int
        public var saves: Int = 0
        public init(rows: Int = rowsCount, saves: Int = 0) {
            self.rows = rows
            self.saves = saves
        }
    }

    public static func view(_ s: Page, _ cx: inout Cx<Page>) -> El<Page> {
        var rowsCol: El<Page> = col().wFull()
        let rowStyle = TextStyle(size: 12, weight: 400)
        for i in 0..<s.rows {
            rowsCol = rowsCol.child(
                row()
                    .key("r\(i)")
                    .wFull()
                    .h(28)
                    .px(12)
                    .centerY()
                    .bg(Color.white.alpha(0.04))
                    .child(text("row \(i): the quick brown fox jumps over the lazy dog").font(rowStyle))
            )
        }
        return col()
            .key("settings")
            .sizeFull()
            .child(
                row()
                    .wFull()
                    .h(40)
                    .child(
                        el()
                            .key("save")
                            .size(80, 30)
                            .onClick { s, _ in s.saves += 1 }
                    )
                    .child(text("saved \(s.saves)").font(rowStyle))
            )
            .child(
                col()
                    .key("list")
                    .wFull()
                    .h(size.y - 40)
                    .scroll(stickBottom: false)
                    .child(rowsCol)
            )
    }

    private static func currentAllocCount() -> UInt64 {
        let counted = ProcessCountingAllocator.shared.threadAllocations()
        if counted > 0 { return counted }
        #if canImport(Darwin)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt64(stats.blocks_in_use)
        #else
        return 0
        #endif
    }

    public static func sampleScenario(_ scenario: Int, frames: Int = defaultFrames, rows: Int = rowsCount) -> [Double] {
        let rt = Runtime(
            state: Page(rows: rows),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var now = 0.0
        _ = rt.frame(at: now)
        for _ in 0..<240 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            if !rt.isAnimating { break }
        }
        let savePos = rt.find("save") ?? Vec2(40, 15)
        var times: [Double] = []
        times.reserveCapacity(frames)
        var totalAllocDelta: Double = 0
        for i in 0..<frames {
            now += 1.0 / 120.0
            let a0 = currentAllocCount()
            let t0 = ContinuousClock.now
            switch scenario {
            case 0:
                rt.pointerDown(at: savePos, at: now)
                rt.pointerUp(at: savePos, at: now)
            case 1:
                let dy: Float = i < frames / 2 ? -10.0 : 10.0
                rt.wheel(WheelEvent(dy: dy), at: Vec2(400, 300), now: now)
            default:
                break
            }
            _ = rt.frame(at: now)
            let elapsed = t0.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15
            times.append(ms)
            let a1 = currentAllocCount()
            if a1 >= a0 {
                totalAllocDelta += Double(a1 - a0)
            }
        }
        let mean = times.reduce(0.0, +) / Double(max(1, frames))
        times.sort()
        let p50 = times[frames / 2]
        return [p50, mean, totalAllocDelta / Double(max(1, frames))]
    }

    public struct MetricLine: Sendable, Equatable {
        public let scenario: String
        public let metric: String
        public let median: Double
        public let p95: Double
        public let count: Int
    }

    public static func runReport(samples: Int = defaultSamples, frames: Int = defaultFrames, rows: Int = rowsCount) -> (lines: [MetricLine], output: String) {
        var collected = Array(repeating: [[Double]](), count: scenarios.count)
        for s in 0...samples {
            for k in 0..<scenarios.count {
                let scenario = (s + k) % scenarios.count
                let row = sampleScenario(scenario, frames: frames, rows: rows)
                if s > 0 {
                    collected[scenario].append(row)
                }
            }
        }
        let perf = ProcessInfo.processInfo.environment["RUNE_PERF"] ?? ""
        var outMetrics: [MetricLine] = []
        var lines: [String] = []
        for (scenarioIdx, rows) in collected.enumerated() where !rows.isEmpty {
            for (mIdx, metricName) in metrics.enumerated() {
                let vals = rows.map { $0[mIdx] }.sorted()
                let p95Idx = Int((Double(vals.count - 1) * 0.95).rounded())
                let median = vals[vals.count / 2]
                let p95 = vals[p95Idx]
                outMetrics.append(MetricLine(
                    scenario: scenarios[scenarioIdx],
                    metric: metricName,
                    median: median,
                    p95: p95,
                    count: vals.count
                ))
                lines.append(String(
                    format: "METRIC perf=%@ scenario=%@ metric=%@ median=%.4f p95=%.4f n=%d",
                    perf,
                    scenarios[scenarioIdx],
                    metricName,
                    median,
                    p95,
                    vals.count
                ))
            }
        }
        return (outMetrics, lines.joined(separator: "\n"))
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let samples: Int
        if let idx = args.firstIndex(of: "--samples"), idx + 1 < args.count, let parsed = Int(args[idx + 1]), parsed > 0 {
            samples = parsed
        } else {
            samples = defaultSamples
        }
        let (_, output) = runReport(samples: samples)
        print(output)
    }
}
