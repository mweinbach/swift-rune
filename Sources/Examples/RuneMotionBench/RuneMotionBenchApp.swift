import Foundation
import RuneMotion

/// Parity port of `crates/rune-motion/examples/bench.rs`:
/// Headless per-frame sampling cost across `AnimationStore`, `Scene`, and standalone `Spring.sample`.
@main
public enum RuneMotionBenchApp {
    public struct BenchmarkRow: Sendable, Equatable {
        public let label: String
        public let count: Int
        public let unit: String
        public let nsPerItem: Double
        public let msPerFrame: Double
    }

    public static let xProp = Prop<Float>.custom(64, .spatial, name: "bench.x")
    public static let defaultFrames = 120
    public static let defaultRuns = 9

    @inline(never)
    private static func consume(_ value: Int) {
        withExtendedLifetime(value) {}
    }

    @inline(never)
    private static func consume(_ value: Float) {
        withExtendedLifetime(value) {}
    }

    private static func padRight(_ s: String, to width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    /// Builds a store, then times `frames` ticks at 120 Hz. Returns ns per track per tick.
    public static func benchStore(
        label: String,
        tracks: Int,
        frames: Int = defaultFrames,
        runs: Int = defaultRuns,
        setup: (inout AnimationStore, NodeId, Int) -> Void
    ) -> BenchmarkRow {
        var bestNs = Double.infinity
        for _ in 0..<runs {
            var st = AnimationStore.withCapacity(tracks: tracks, lanesPerTrack: 4)
            for i in 0..<tracks {
                setup(&st, NodeId(UInt64(i)), i)
            }
            st.tickAt(0.0)
            let t0 = ContinuousClock.now
            for f in 1...frames {
                st.tickAt(Double(f) / 120.0)
                consume(st.events.count)
            }
            let elapsed = t0.duration(to: .now)
            let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            precondition(st.activeLen == tracks, "\(label): every track must still be active (got \(st.activeLen)/\(tracks))")
            bestNs = min(bestNs, ns / Double(frames * tracks))
        }
        return BenchmarkRow(
            label: label,
            count: tracks,
            unit: "tracks",
            nsPerItem: bestNs,
            msPerFrame: bestNs * Double(tracks) / 1e6
        )
    }

    /// Times `Scene` layout reflow -> `Presented` over `frames` ticks at 120 Hz.
    public static func benchScene(
        nodes: Int,
        frames: Int = defaultFrames,
        runs: Int = defaultRuns
    ) -> BenchmarkRow {
        var bestNs = Double.infinity
        for _ in 0..<runs {
            var s = Scene()
            for i in 0..<nodes {
                let id = NodeId(UInt64(i))
                s.insert(id, NodeSpec(MotionRect.fromXYWH(0, Float(i) * 20.0, 300, 20)), .initial)
            }
            _ = s.frameAt(0.0)
            for i in 0..<nodes {
                s.setFrame(
                    NodeId(UInt64(i)),
                    MotionRect.fromXYWH(10, Float(i) * 24.0, 300, 24),
                    Spring(duration: 3.0, bounce: 0.0)
                )
            }
            _ = s.frameAt(1.0 / 120.0)
            let t0 = ContinuousClock.now
            for f in 2..<(frames + 2) {
                let out = s.frameAt(Double(f) / 120.0)
                consume(out.changed.count)
            }
            let elapsed = t0.duration(to: .now)
            let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            bestNs = min(bestNs, ns / Double(frames * nodes))
        }
        return BenchmarkRow(
            label: "scene: layout reflow → Presented",
            count: nodes,
            unit: "nodes",
            nsPerItem: bestNs,
            msPerFrame: bestNs * Double(nodes) / 1e6
        )
    }

    /// Raw closed-form `Spring.sample` benchmark without `AnimationStore`.
    public static func benchStandaloneSample(iters: Int = 2_000_000, runs: Int = defaultRuns) -> Double {
        let s = Spring(duration: 0.5, bounce: 0.3)
        var bestNs = Double.infinity
        for _ in 0..<runs {
            let t0 = ContinuousClock.now
            var acc: Float = 0.0
            for i in 0..<iters {
                let (x, v) = s.sample(from: 0.0, velocity: 0.0, target: 1.0, at: Float(i % 1000) * 1e-3)
                acc += x + v
            }
            consume(acc)
            let elapsed = t0.duration(to: .now)
            let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            bestNs = min(bestNs, ns / Double(iters))
        }
        return bestNs
    }

    public static func runReport(
        trackCounts: [Int] = [10_000, 100_000],
        sceneCounts: [Int] = [1_000, 10_000],
        frames: Int = defaultFrames,
        runs: Int = defaultRuns,
        sampleIters: Int = 2_000_000
    ) -> (rows: [BenchmarkRow], sampleNsPerCall: Double, text: String) {
        var rows: [BenchmarkRow] = []
        var lines: [String] = ["rune-motion bench (\(frames) frames at 120 Hz, best of \(runs))", ""]

        for n in trackCounts {
            let batch: [BenchmarkRow] = [
                benchStore(label: "scalar springs, underdamped (bounce .3)", tracks: n, frames: frames, runs: runs) { st, id, i in
                    st.set(id, xProp, 0.0)
                    st.animate(id, xProp, to: 100.0 + Float(i % 13), anim: .spring(Spring(duration: 3.0, bounce: 0.3)))
                },
                benchStore(label: "scalar springs, critical (bounce 0)", tracks: n, frames: frames, runs: runs) { st, id, i in
                    st.set(id, xProp, 0.0)
                    st.animate(id, xProp, to: 100.0 + Float(i % 13), anim: .spring(Spring(duration: 3.0, bounce: 0.0)))
                },
                benchStore(label: "scalar tweens (ease-in-out bezier)", tracks: n, frames: frames, runs: runs) { st, id, i in
                    st.set(id, xProp, 0.0)
                    st.animate(id, xProp, to: 100.0 + Float(i % 13), anim: Anim(curve: Curve.easeInOut(5.0)))
                },
                benchStore(label: "rect frames (4 edge lanes, MORPH)", tracks: n, frames: frames, runs: runs) { st, id, i in
                    st.set(id, Props.FRAME, MotionRect.fromXYWH(0.0, 0.0, 10.0, 10.0))
                    let f = Float(i % 17)
                    st.animate(id, Props.FRAME, to: MotionRect.fromXYWH(100.0 + f, 50.0, 300.0, 200.0), anim: .spring(Spring(duration: 3.0, bounce: 0.16)))
                },
                benchStore(label: "colors (4 OKLab lanes)", tracks: n, frames: frames, runs: runs) { st, id, _ in
                    st.set(id, Props.FILL, MotionColor.hex(0xff3b30))
                    st.animate(id, Props.FILL, to: MotionColor.hex(0x007aff), anim: .spring(Spring(duration: 3.0, bounce: 0.0)))
                },
                benchStore(label: "mixed: 1/3 spring, 1/3 tween, 1/3 additive x2", tracks: n, frames: frames, runs: runs) { st, id, i in
                    st.set(id, xProp, 0.0)
                    switch i % 3 {
                    case 0:
                        st.animate(id, xProp, to: 50.0, anim: .spring(Spring(duration: 3.0, bounce: 0.2)))
                    case 1:
                        st.animate(id, xProp, to: 50.0, anim: Anim(curve: Curve.easeInOut(5.0)))
                    default:
                        st.animate(id, xProp, to: 50.0, anim: .spring(Spring(duration: 3.0, bounce: 0.0)))
                        st.animate(id, xProp, to: 80.0, anim: .spring(Spring(duration: 3.0, bounce: 0.0)).additive())
                    }
                },
            ]
            rows.append(contentsOf: batch)
            for row in batch {
                lines.append(String(
                    format: "%@ %7d tracks  %7.2f ns/track  %7.3f ms/frame",
                    padRight(row.label, to: 44),
                    row.count,
                    row.nsPerItem,
                    row.msPerFrame
                ))
            }
            lines.append("")
        }

        for n in sceneCounts {
            let row = benchScene(nodes: n, frames: frames, runs: runs)
            rows.append(row)
            lines.append(String(
                format: "%@ %7d nodes   %7.2f ns/node   %7.3f ms/frame",
                padRight(row.label, to: 44),
                row.count,
                row.nsPerItem,
                row.msPerFrame
            ))
        }

        let sampleNs = benchStandaloneSample(iters: sampleIters, runs: runs)
        lines.append("")
        lines.append(String(format: "Spring::sample (closed form, standalone)   %7.2f ns/call", sampleNs))
        return (rows, sampleNs, lines.joined(separator: "\n"))
    }

    public static func main() {
        let (_, _, text) = runReport()
        print(text)
    }
}
