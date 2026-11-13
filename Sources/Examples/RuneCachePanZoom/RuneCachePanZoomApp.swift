import Foundation
import Rune
import RunePerf
#if canImport(Metal)
import Metal
#endif

/// Parity port of `crates/rune/examples/cache_pan_zoom.rs`:
/// Headless benchmark for `El.cache()`: 25 text-heavy cards under live pan and zoom.
@main
public enum RuneCachePanZoomApp {
    public static let size = Vec2(1280, 820)
    public static let cols = 5
    public static let metrics = [
        "cpu_ms",
        "paint_ms",
        "encode_ms",
        "instances",
        "extra_passes",
        "targets",
        "cache_kb",
        "allocations",
    ]

    public struct CardData: Sendable {
        public let key: String
        public let title: String
        public let badge: String
        public let version: String
        public let line1: String
        public let line2: String
        public let line3: String
        public let footer: String
    }

    public struct State: Sendable {
        public var cached: Bool
        public var pan: Live<Vec2>
        public var zoom: Live<Float>
        public var cards: [CardData]

        public init(cached: Bool, count: Int) {
            self.cached = cached
            self.pan = Live(Vec2(0, 0))
            self.zoom = Live(1.0)
            self.cards = (0..<count).map { i in
                let idx = String(format: "%02d", i)
                let lat1 = String(format: "%.2f", 0.42 + Double(i) * 0.03)
                let lat2 = String(format: "%.2f", 1.15 + Double(i) * 0.05)
                return CardData(
                    key: "card-\(idx)",
                    title: "Subsystem Pipeline #\(idx)",
                    badge: i % 2 == 0 ? "READY" : "SYNCED",
                    version: "v2.\(i % 9).\((i * 3) % 14)",
                    line1: "Offscreen tile cache node \(idx) rasterizes glyphs and borders once.",
                    line2: "Ancestor live_offset and live_scale composite without reshaping (\(i) shards).",
                    line3: "Latency p50 \(lat1)ms · p99 \(lat2)ms · throughput \(120 + i * 7)k ops/s",
                    footer: "region-us-east-\((i % 4) + 1) · replica \((i % 3) + 1) · 120 Hz"
                )
            }
        }
    }

    private static let bg = Color(r: 0.012, g: 0.014, b: 0.018, a: 1.0)
    private static let cardBg = Color(r: 0.032, g: 0.036, b: 0.046, a: 1.0)
    private static let borderColor = Color(r: 0.12, g: 0.14, b: 0.18, a: 1.0)
    private static let badgeBg = Color(r: 0.08, g: 0.22, b: 0.16, a: 1.0)
    private static let badgeFg = Color(r: 0.35, g: 0.88, b: 0.62, a: 1.0)
    private static let textColor = Color(r: 0.88, g: 0.90, b: 0.94, a: 1.0)
    private static let bodyColor = Color(r: 0.58, g: 0.62, b: 0.68, a: 1.0)
    private static let mutedColor = Color(r: 0.36, g: 0.40, b: 0.46, a: 1.0)
    private static let accentColor = Color(r: 0.24, g: 0.52, b: 0.96, a: 1.0)

    private static func cardView(_ c: CardData, cached: Bool) -> El<State> {
        let headerRow: El<State> = row()
            .wFull()
            .gap(6)
            .centerY()
            .child(
                el().px(6).py(2).rounded(4).bg(badgeBg)
                    .child(text(c.badge).font(TextStyle(size: 10, weight: 600)).color(badgeFg))
            )
            .child(text(c.title).font(TextStyle(size: 13, weight: 600)).color(textColor).grow(1))
            .child(text(c.version).font(TextStyle(size: 11, weight: 500)).color(mutedColor))
        let footerRow: El<State> = row()
            .wFull()
            .gap(6)
            .centerY()
            .child(el().size(8, 8).rounded(4).bg(accentColor))
            .child(text(c.footer).font(TextStyle(size: 10, weight: 500)).color(mutedColor).grow(1))
            .child(el().size(36, 4).rounded(2).bg(accentColor))

        var node: El<State> = col()
            .key(c.key)
            .size(228, 136)
            .p(10)
            .gap(5)
            .rounded(8)
            .bg(cardBg)
            .border(1, borderColor)
            .child(headerRow)
            .child(text(c.line1).font(TextStyle(size: 11, weight: 400)).color(bodyColor))
            .child(text(c.line2).font(TextStyle(size: 11, weight: 400)).color(bodyColor))
            .child(text(c.line3).font(TextStyle(size: 11, weight: 400)).color(bodyColor))
            .child(footerRow)
        if cached {
            node = node.cache(true)
        }
        return node
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        var grid: El<State> = col().gap(10)
        var idx = 0
        var rowIdx = 0
        while idx < s.cards.count {
            var line: El<State> = row().key("row-\(rowIdx)").gap(10)
            let end = min(s.cards.count, idx + cols)
            for c in s.cards[idx..<end] {
                line = line.child(cardView(c, cached: s.cached))
            }
            grid = grid.child(line)
            idx = end
            rowIdx += 1
        }
        return el()
            .wFull()
            .hFull()
            .bg(bg)
            .p(32)
            .child(
                el()
                    .key("canvas")
                    .size(1200, 740)
                    .liveOffset(Binding(live: s.pan))
                    .liveScale(Binding(live: s.zoom))
                    .child(grid)
            )
    }

    public struct MetricLine: Sendable, Equatable {
        public let mode: String
        public let testCase: String
        public let metric: String
        public let median: Double
        public let p95: Double
        public let count: Int
    }

    public static func runReport(
        samples: Int = 15,
        cards: Int = 25,
        frames: Int = 60
    ) throws -> (lines: [MetricLine], output: String) {
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.x * 2),
            height: Int(size.y * 2),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        guard let targetTex = renderer.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "RuneCachePanZoom", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"])
        }

        func runSample(cached: Bool, testCase: String) -> [Double] {
            let ts = TextSystem()
            for sz: Float in [10, 11, 13] {
                _ = ts.shape(text: "Warm benchmark fonts 0123456789", style: TextStyle(size: sz, weight: 400), maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
            }
            let state = State(cached: cached, count: cards)
            let pan = state.pan
            let zoom = state.zoom
            let rt = Runtime(state: state, viewport: size, pixelScale: 2.0, systemDark: true, textSystem: ts, view: view)

            var now = 0.0
            let f0 = rt.renderFrame(at: now)
            if let cb = renderer.commandQueue.makeCommandBuffer() {
                renderer.drawRange(frame: f0, into: targetTex, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
            }
            for _ in 0..<60 {
                now += 1.0 / 120.0
                _ = rt.frame(at: now)
                if !rt.isAnimating { break }
            }
            let warmFrame = rt.renderFrame(at: now)
            if let cb = renderer.commandQueue.makeCommandBuffer() {
                renderer.drawRange(frame: warmFrame, into: targetTex, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
            }

            var totalCpu = 0.0
            var totalPaint = 0.0
            var totalEncode = 0.0
            var totalInstances = 0.0
            var totalExtraPasses = 0.0
            var totalAllocs = 0.0

            for f in 0..<frames {
                let t = Float(f + 1) / Float(max(1, frames))
                let angle = t * Float.pi * 2
                if testCase == "pan" {
                    pan.set(Vec2(cos(angle) * 24, sin(angle) * 18))
                } else {
                    pan.set(Vec2(cos(angle) * 12, sin(angle) * 10))
                    zoom.set(1.0 + 0.25 * t)
                }
                now += 1.0 / 120.0
                _ = takeFramePhases()
                let alloc0 = ProcessCountingAllocator.shared.threadAllocations()
                let cpu0 = threadCpuMs()
                let rf = rt.renderFrame(at: now)
                let cpu = max(0, threadCpuMs() - cpu0)
                let allocs = Double(max(0, Int64(ProcessCountingAllocator.shared.threadAllocations()) - Int64(alloc0)))
                let phases = takeFramePhases()
                let paint = phases.count > 4 ? phases[4] : 0

                let encStart = ContinuousClock.now
                if let cb = renderer.commandQueue.makeCommandBuffer() {
                    renderer.drawRange(frame: rf, into: targetTex, commandBuffer: cb)
                    cb.commit()
                    cb.waitUntilCompleted()
                }
                let encDur = encStart.duration(to: .now)
                let encodeMs = Double(encDur.components.seconds) * 1000.0 + Double(encDur.components.attoseconds) / 1e15

                let stats = renderer.layerStats()
                totalCpu += cpu
                totalPaint += paint
                totalEncode += encodeMs
                totalInstances += Double(rf.instances.count)
                totalExtraPasses += Double(stats.extraPasses)
                totalAllocs += allocs
            }

            let n = Double(max(1, frames))
            let stats = renderer.layerStats()
            return [
                totalCpu / n,
                totalPaint / n,
                totalEncode / n,
                totalInstances / n,
                totalExtraPasses / n,
                Double(stats.targets),
                Double(stats.bytes) / 1024.0,
                totalAllocs / n,
            ]
        }

        var lines: [MetricLine] = []
        var textLines: [String] = []
        for (mode, cached) in [("uncached", false), ("cached", true)] {
            for testCase in ["pan", "pan_zoom"] {
                var rows: [[Double]] = []
                for s in 0...samples {
                    let r = runSample(cached: cached, testCase: testCase)
                    if s > 0 { rows.append(r) }
                }
                for (m, name) in metrics.enumerated() {
                    let v = rows.map { $0[m] }.sorted()
                    let p95 = v[Int((Double(v.count - 1) * 0.95).rounded())]
                    let med = v[v.count / 2]
                    lines.append(MetricLine(mode: mode, testCase: testCase, metric: name, median: med, p95: p95, count: v.count))
                    textLines.append(String(
                        format: "METRIC mode=%@ case=%@ metric=%@ median=%.4f p95=%.4f n=%d",
                        mode, testCase, name, med, p95, v.count
                    ))
                }
            }
        }
        return (lines, textLines.joined(separator: "\n"))
        #else
        return ([], "cache_pan_zoom: Metal unavailable on this platform")
        #endif
    }

    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func intArg(_ flag: String, default def: Int) -> Int {
            if let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Int(args[i + 1]), v > 0 { return v }
            return def
        }
        let (_, output) = try runReport(
            samples: intArg("--samples", default: 15),
            cards: intArg("--cards", default: 25),
            frames: intArg("--frames", default: 60)
        )
        print(output)
    }
}
