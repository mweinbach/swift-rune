import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif

/// Parity port of `crates/rune/examples/scroll_commits.rs`:
/// 120 frames of wheel scrolling a 300-row list when the list holds a playing video
/// or a view reads a row's layout (`Cx.layout` + `memo` + `layoutRect`).
@main
public enum RuneScrollCommitsApp {
    public static let size = Vec2(800, 600)
    public static let rowCount = 300
    public static let defaultFrames = 120
    public static let defaultSamples = 9
    public static let metrics = ["commits", "cpu_p50_ms", "cpu_mean_ms", "allocations"]

    public struct ListState: @unchecked Sendable {
        public var video: Player?

        public init(video: Player? = nil) {
            self.video = video
        }
    }

    public struct ScenarioResult: Sendable, Equatable {
        public let scenario: String
        public let commits: Int
        public let cpuP50Ms: Double
        public let cpuMeanMs: Double
        public let allocations: Double
        public let frames: Int
    }

    public struct MetricLine: Sendable, Equatable {
        public let scenario: String
        public let metric: String
        public let median: Double
        public let p95: Double
        public let count: Int
    }

    public struct Report: Sendable {
        public let results: [ScenarioResult]
        public let lines: [MetricLine]
        public let output: String
    }

    public static func fixtureVideoURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests")
            .appendingPathComponent("RuneTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("rgbw.mp4")
    }

    private static func buildRows() -> El<ListState> {
        var c: El<ListState> = col().wFull()
        let rowStyle = TextStyle(size: 12, weight: 400)
        for i in 0..<rowCount {
            c = c.child(
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
        return c
    }

    public static func view(_ s: ListState, _ cx: inout Cx<ListState>) -> El<ListState> {
        var content: El<ListState> = col().wFull()
        if let v = s.video {
            content = content
                .child(el().h(100))
                .child(el().key("clip").size(320, 180).video(v, .fit))
        }
        let list = col()
            .key("list")
            .wFull()
            .h(size.y - 40)
            .scroll(stickBottom: false)
            .child(content.child(buildRows()))

        var root: El<ListState> = col().wFull().hFull().child(list)
        if s.video == nil {
            let r20 = cx.layout("r20").map { $0[1] } ?? -1.0
            let r10El: El<ListState> = memo("r10-label", 0) {
                text("r10 \(layoutRect("r10").map { "\($0)" } ?? "nil")")
                    .font(TextStyle(size: 12, weight: 400))
            }
            root = root.child(
                row()
                    .wFull()
                    .h(40)
                    .child(text("r20 at \(r20)").font(TextStyle(size: 12, weight: 400)))
                    .child(r10El)
            )
        }
        return root
    }

    private static func liveMallocBlocks() -> UInt {
        #if canImport(Darwin)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt(stats.blocks_in_use)
        #else
        return 0
        #endif
    }

    public static func sample(video withVideo: Bool, frames: Int = defaultFrames) -> [Double] {
        var player: Player? = nil
        if withVideo {
            let url = fixtureVideoURL()
            precondition(FileManager.default.fileExists(atPath: url.path), "Missing fixture video: \(url.path)")
            let v = Player.file(url.path)
            v.setLooping(true)
            v.play()
            player = v
        }
        let rt = Runtime(
            state: ListState(video: player),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var now = 0.0
        for _ in 0..<240 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            if !rt.isAnimating { break }
        }
        let commits0 = rt.viewCommitCount
        var cpu: [Double] = []
        cpu.reserveCapacity(frames)
        var allocations = 0.0
        for i in 0..<frames {
            // Down 600 points, then back up: the clip leaves through the top edge and returns.
            let dy: Float = (i < frames / 2) ? -10.0 : 10.0
            let alloc0 = liveMallocBlocks()
            let cpu0 = threadCpuMs()
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(400, 300), now: now)
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            cpu.append(threadCpuMs() - cpu0)
            allocations += Double(max(0, Int64(liveMallocBlocks()) - Int64(alloc0)))
        }
        let mean = cpu.isEmpty ? 0.0 : cpu.reduce(0, +) / Double(frames)
        cpu.sort()
        let p50 = cpu.isEmpty ? 0.0 : cpu[frames / 2]
        return [
            Double(rt.viewCommitCount - commits0),
            p50,
            mean,
            allocations / Double(max(1, frames)),
        ]
    }

    public static func runReport(samples: Int = defaultSamples, frames: Int = defaultFrames) -> Report {
        var rows: [[[Double]]] = [[], []]
        // One warm-up of each, then alternate so heat and caches favour neither scenario.
        for s in 0...samples {
            let order = (s % 2 == 0) ? [false, true] : [true, false]
            for isVideo in order {
                let row = sample(video: isVideo, frames: frames)
                if s > 0 {
                    rows[isVideo ? 1 : 0].append(row)
                }
            }
        }

        var outputLines: [String] = []
        var metricLines: [MetricLine] = []
        var results: [ScenarioResult] = []
        for (videoIdx, group) in rows.enumerated() {
            let scenario = (videoIdx == 1) ? "video" : "layout"
            guard !group.isEmpty else { continue }
            var medians: [Double] = []
            for (m, name) in metrics.enumerated() {
                var v = group.map { $0[m] }
                v.sort()
                let med = v[v.count / 2]
                let p95 = v[min(v.count - 1, Int((Double(v.count - 1) * 0.95).rounded()))]
                medians.append(med)
                metricLines.append(MetricLine(scenario: scenario, metric: name, median: med, p95: p95, count: v.count))
                outputLines.append(String(
                    format: "METRIC scenario=%@ metric=%@ median=%.4f p95=%.4f n=%d",
                    scenario, name, med, p95, v.count
                ))
            }
            results.append(ScenarioResult(
                scenario: scenario,
                commits: Int(medians[0].rounded()),
                cpuP50Ms: medians[1],
                cpuMeanMs: medians[2],
                allocations: medians[3],
                frames: frames
            ))
        }
        return Report(results: results, lines: metricLines, output: outputLines.joined(separator: "\n"))
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let samples = args.firstIndex(of: "--samples").flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } ?? defaultSamples
        let report = runReport(samples: samples, frames: defaultFrames)
        print(report.output)
    }
}
