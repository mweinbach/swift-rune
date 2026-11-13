import Foundation
import Rune

/// Parity port of `crates/rune/examples/scroll_commits.rs`:
/// Measures view commits and CPU frame cost across pure scroll frames when a list holds
/// either a playing video clip scrolled across the viewport edge or a `Cx.layout` + `memo` read.
@main
public enum RuneScrollCommitsApp {
    public static let size = Vec2(800, 600)
    public static let rowCount = 300

    public final class ViewCounter: @unchecked Sendable {
        public var builds: Int = 0
    }

    public struct State: @unchecked Sendable {
        public var video: Player?
        public let counter = ViewCounter()

        public init(video: Player? = nil) {
            self.video = video
        }
    }

    public struct ScenarioResult: Sendable, Equatable {
        public let scenario: String
        public let commits: Int
        public let cpuP50Ms: Double
        public let cpuMeanMs: Double
        public let frames: Int
    }

    public struct Report: Sendable {
        public let results: [ScenarioResult]
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

    private static func buildRows() -> El<State> {
        var c: El<State> = col().wFull()
        let rowStyle = TextStyle(size: 12, weight: 400)
        for i in 0..<rowCount {
            c = c.child(
                row()
                    .key("r\(i)")
                    .wFull()
                    .h(28)
                    .px(12)
                    .itemsCenter()
                    .bg(Color.white.alpha(0.04))
                    .child(text("row \(i): the quick brown fox jumps over the lazy dog").font(rowStyle))
            )
        }
        return c
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        s.counter.builds += 1
        var content: El<State> = col().wFull()
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

        var root: El<State> = col().wFull().hFull().child(list)
        if s.video == nil {
            let r20Y = cx.layout("r20").map { $0[1] } ?? -1.0
            let r10El: El<State> = memo("r10-label", 0) {
                text("r10 \(layoutRect("r10").map { "\($0)" } ?? "nil")")
                    .font(TextStyle(size: 12, weight: 400))
            }
            root = root.child(
                row()
                    .wFull()
                    .h(40)
                    .child(text(String(format: "r20 at %.1f", r20Y)).font(TextStyle(size: 12, weight: 400)))
                    .child(r10El)
            )
        }
        return root
    }

    public static func runSample(video withVideo: Bool, frames: Int = 120) -> ScenarioResult {
        var player: Player? = nil
        if withVideo {
            let url = fixtureVideoURL()
            if FileManager.default.fileExists(atPath: url.path) {
                let p = Player(source: .file(url), playing: true, looping: true)
                p.play()
                player = p
            }
        }
        let rt = Runtime(
            state: State(video: player),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var now = 0.0
        for _ in 0..<24 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            if !rt.isAnimating { break }
        }
        let builds0 = rt.state.counter.builds
        var cpu: [Double] = []
        cpu.reserveCapacity(frames)
        for i in 0..<frames {
            let dy: Float = (i < frames / 2) ? -10.0 : 10.0
            let cpu0 = threadCpuMs()
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(400, 300), now: now)
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            cpu.append(threadCpuMs() - cpu0)
        }
        let mean = cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count)
        let sorted = cpu.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return ScenarioResult(
            scenario: withVideo ? "video" : "layout",
            commits: rt.state.counter.builds - builds0,
            cpuP50Ms: p50,
            cpuMeanMs: mean,
            frames: frames
        )
    }

    public static func runReport(samples: Int = 3, frames: Int = 120) -> Report {
        var layoutRuns: [ScenarioResult] = []
        var videoRuns: [ScenarioResult] = []
        for s in 0...samples {
            let order = (s % 2 == 0) ? [false, true] : [true, false]
            for isVideo in order {
                let res = runSample(video: isVideo, frames: frames)
                if s > 0 || samples == 1 {
                    if isVideo { videoRuns.append(res) } else { layoutRuns.append(res) }
                }
            }
        }
        let combined = [layoutRuns, videoRuns].compactMap { group -> ScenarioResult? in
            guard !group.isEmpty else { return nil }
            let medIdx = group.count / 2
            let sortedCommits = group.map { $0.commits }.sorted()
            let sortedP50 = group.map { $0.cpuP50Ms }.sorted()
            let sortedMean = group.map { $0.cpuMeanMs }.sorted()
            return ScenarioResult(
                scenario: group[0].scenario,
                commits: sortedCommits[medIdx],
                cpuP50Ms: sortedP50[medIdx],
                cpuMeanMs: sortedMean[medIdx],
                frames: frames
            )
        }
        var lines: [String] = []
        for r in combined {
            lines.append("METRIC scenario=\(r.scenario) metric=commits median=\(r.commits) frames=\(r.frames)")
            lines.append(String(format: "METRIC scenario=%@ metric=cpu_p50_ms median=%.4f", r.scenario, r.cpuP50Ms))
            lines.append(String(format: "METRIC scenario=%@ metric=cpu_mean_ms median=%.4f", r.scenario, r.cpuMeanMs))
        }
        return Report(results: combined, output: lines.joined(separator: "\n"))
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let samples = args.firstIndex(of: "--samples").flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } ?? 5
        let report = runReport(samples: samples, frames: 120)
        print(report.output)
    }
}
