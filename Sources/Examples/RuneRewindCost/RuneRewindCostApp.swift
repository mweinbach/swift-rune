import Foundation
import Rune
import RunePerf

/// Parity port of `crates/rune/examples/rewind_cost.rs`:
/// Measures CPU/allocation overhead of `Tx.recordRewind` across stream, scroll, fold, and idle scenarios.
@main
public enum RuneRewindCostApp {
    public static let size = Vec2(1000, 800)
    public static let initialRows = 400
    public static let defaultFrames = 240
    public static let defaultSamples = 5
    public static let scenarios = ["stream", "scroll", "fold", "idle"]

    public struct Page: @unchecked Sendable {
        public var rows: Int
        public var tail: Int
        public var open: Bool
        public var rewind: RewindRecorder

        public init(rows: Int = initialRows, tail: Int = 0, open: Bool = false, rewind: RewindRecorder = RewindRecorder()) {
            self.rows = rows
            self.tail = tail
            self.open = open
            self.rewind = rewind
        }
    }

    public static func view(_ s: Page, _ cx: inout Cx<Page>) -> El<Page> {
        let style = TextStyle(size: 13, weight: 400)
        var transcript: El<Page> = col().wFull().gap(6)
        for i in 0..<s.rows {
            let body: String
            if i + 1 == s.rows {
                body = String(repeating: "streaming words ", count: 1 + s.tail / 4)
            } else {
                body = "message \(i): the quick brown fox jumps over the lazy dog"
            }
            let rowEl: El<Page> = col()
                .key("m\(i)")
                .wFull()
                .px(16)
                .py(8)
                .gap(4)
                .bg(Color.white.alpha(0.04))
                .child(
                    row()
                        .key("m\(i)-head")
                        .gap(8)
                        .child(el().key("m\(i)-face").size(18, 18).rounded(9).bg(Color.white.alpha(0.2)))
                        .child(text("agent \(i % 7)").font(style))
                )
                .child(text(body).key("m\(i)-body").font(style))
            transcript = transcript.child(rowEl)
        }
        var fold: El<Page> = col()
            .key("fold")
            .wFull()
            .h(s.open ? 240 : 0)
            .clipRounded(0)
        for i in 0..<12 {
            let lineEl: El<Page> = row().key("fold-\(i)").h(20).child(text("tool output line \(i)").font(style))
            fold = fold.child(lineEl)
        }
        return col()
            .key("page")
            .sizeFull()
            .child(row().key("header").wFull().h(40).px(16).centerY().child(text("Session").font(style)))
            .child(fold)
            .child(
                col()
                    .key("transcript")
                    .wFull()
                    .grow(1)
                    .scroll(stickBottom: true)
                    .child(transcript)
            )
    }

    public struct ScenarioRun: Sendable {
        public let timesMs: [Double]
        public let allocsPerFrame: UInt64
        public let recordedFrames: Int
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

    public static func runScenario(_ scenario: Int, record: Bool, frames: Int = defaultFrames, rows: Int = initialRows) -> ScenarioRun {
        let rt = Runtime(
            state: Page(rows: rows),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        if record {
            rt.update { s, tx in tx.recordRewind(s.rewind) }
        }
        var now = 0.0
        _ = rt.frame(at: now)
        for _ in 0..<240 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            if !rt.isAnimating { break }
        }
        var times: [Double] = []
        times.reserveCapacity(frames)
        var allocs: UInt64 = 0
        for i in 0..<frames {
            now += 1.0 / 120.0
            let a0 = currentAllocCount()
            let t0 = ContinuousClock.now
            switch scenario {
            case 0:
                rt.update(at: now) { s, _ in
                    s.tail += 1
                    if s.tail % 8 == 0 { s.rows += 1 }
                }
            case 1:
                let dy: Float = (i / 40) % 2 == 0 ? -24.0 : 24.0
                rt.wheel(WheelEvent(dy: dy), at: Vec2(500, 400), now: now)
            case 2:
                if i % 30 == 0 {
                    rt.update(at: now) { s, _ in s.open.toggle() }
                }
            default:
                break
            }
            _ = rt.frame(at: now)
            let elapsed = t0.duration(to: .now)
            times.append(Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15)
            let a1 = currentAllocCount()
            if a1 >= a0 { allocs += a1 - a0 }
        }
        let recorded = rt.state.rewind.frameCount
        precondition((recorded > 0) == record, "RewindRecorder recordedFrames=\(recorded), expected record=\(record)")
        return ScenarioRun(timesMs: times, allocsPerFrame: allocs / UInt64(max(1, frames)), recordedFrames: recorded)
    }

    public static func runMinute(frames: Int = 3600, rows: Int = initialRows) -> (bytes: Int, frames: Int) {
        let rt = Runtime(
            state: Page(rows: rows),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        rt.update { s, tx in tx.recordRewind(s.rewind) }
        var now = 0.0
        for i in 0..<frames {
            now += 1.0 / 60.0
            rt.update(at: now) { s, _ in
                s.tail += 1
                if s.tail % 8 == 0 { s.rows += 1 }
                if i % 300 == 0 { s.open.toggle() }
            }
            if i % 600 < 60 {
                rt.wheel(WheelEvent(dy: -24.0), at: Vec2(500, 400), now: now)
            }
            _ = rt.frame(at: now)
        }
        return (rt.state.rewind.estimatedBytes, rt.state.rewind.frameCount)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[idx]
    }

    public static func runReport(
        samples: Int = defaultSamples,
        frames: Int = defaultFrames,
        minuteFrames: Int = 3600,
        rows: Int = initialRows
    ) -> (minuteBytes: Int, minuteFrames: Int, output: String) {
        var lines: [String] = []
        for (k, name) in scenarios.enumerated() {
            var p50Off: [Double] = []
            var p99Off: [Double] = []
            var allocOff: [Double] = []
            var p50On: [Double] = []
            var p99On: [Double] = []
            var allocOn: [Double] = []
            for n in 0..<samples {
                let order = (n % 2 == 0) ? [false, true] : [true, false]
                for record in order {
                    let r = runScenario(k, record: record, frames: frames, rows: rows)
                    let p50 = percentile(r.timesMs, 0.5)
                    let p99 = percentile(r.timesMs, 0.99)
                    if record {
                        p50On.append(p50)
                        p99On.append(p99)
                        allocOn.append(Double(r.allocsPerFrame))
                    } else {
                        p50Off.append(p50)
                        p99Off.append(p99)
                        allocOff.append(Double(r.allocsPerFrame))
                    }
                }
            }
            let pairs: [(String, [Double], [Double])] = [
                ("p50_ms", p50Off, p50On),
                ("p99_ms", p99Off, p99On),
                ("allocations", allocOff, allocOn),
            ]
            for (metric, offVals, onVals) in pairs {
                lines.append(String(format: "METRIC scenario=%@ rewind=off metric=%@ median=%.4f", name, metric, percentile(offVals, 0.5)))
                lines.append(String(format: "METRIC scenario=%@ rewind=on metric=%@ median=%.4f", name, metric, percentile(onVals, 0.5)))
            }
        }
        let (bytes, recFrames) = runMinute(frames: minuteFrames, rows: rows)
        lines.append("METRIC scenario=minute rewind=on metric=bytes median=\(bytes) frames=\(recFrames)")
        return (bytes, recFrames, lines.joined(separator: "\n"))
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let samples: Int
        if let idx = args.firstIndex(of: "--samples"), idx + 1 < args.count, let parsed = Int(args[idx + 1]), parsed > 0 {
            samples = parsed
        } else {
            samples = defaultSamples
        }
        let (_, _, output) = runReport(samples: samples)
        print(output)
    }
}
