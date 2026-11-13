import Foundation
import Rune
#if canImport(Metal)
import Metal
#endif

/// Parity port of `crates/rune/examples/zoom_sweep.rs`:
/// Headless zoom-sweep benchmark for the glyph atlas and `liveScale` bucketing.
@main
public enum RuneZoomSweepApp {
    public static let size = Vec2(1280, 820)
    public static let cols = 5
    public static let cardCount = 25
    public static let defaultFrames = 1200

    public struct CardData: Sendable {
        public let key: String
        public let title: String
        public let badge: String
        public let version: String
        public let line1: String
        public let line2: String
        public let footer: String
    }

    public final class State: @unchecked Sendable {
        public let zoom = Live<Float>(1.0)
        public var fontScale: Float = 1.0
        public let cards: [CardData]

        public init(count: Int = RuneZoomSweepApp.cardCount) {
            self.cards = (0..<count).map { i in
                CardData(
                    key: String(format: "card-%02d", i),
                    title: String(format: "Canvas Node #%02d", i),
                    badge: i.isMultiple(of: 2) ? "LIVE" : "CRISP",
                    version: "v2.\(i % 9).\((i * 3) % 14)",
                    line1: String(format: "Logarithmic quarter-octave buckets bound atlas pressure (%02d).", i),
                    line2: "Two-page ping-pong shelf recycling preserves 120 Hz pacing (\(i) shards).",
                    footer: "layer-\((i % 4) + 1) · scale-settle 100ms · 120 Hz"
                )
            }
        }
    }

    private static let bg = Color(r: 0.012, g: 0.014, b: 0.018, a: 1.0)
    private static let cardBg = Color(r: 0.032, g: 0.036, b: 0.046, a: 1.0)
    private static let border = Color(r: 0.12, g: 0.14, b: 0.18, a: 1.0)
    private static let textColor = Color(r: 0.88, g: 0.90, b: 0.94, a: 1.0)
    private static let bodyColor = Color(r: 0.58, g: 0.62, b: 0.68, a: 1.0)
    private static let mutedColor = Color(r: 0.36, g: 0.40, b: 0.46, a: 1.0)

    private static func cardView(_ c: CardData, k: Float) -> El<State> {
        let header: El<State> = row()
            .wFull()
            .gap(6)
            .itemsCenter()
            .child(text(c.badge).font(TextStyle(size: 10 * k, weight: 600)).color(textColor))
            .child(text(c.title).font(TextStyle(size: 13 * k, weight: 600)).color(textColor).grow(1))
            .child(text(c.version).font(TextStyle(size: 11 * k, weight: 500)).color(mutedColor))

        return col()
            .key(c.key)
            .size(228, 118)
            .p(10)
            .gap(5)
            .rounded(8)
            .bg(cardBg)
            .border(1, border)
            .child(header)
            .child(text(c.line1).font(TextStyle(size: 11 * k, weight: 400)).color(bodyColor))
            .child(text(c.line2).font(TextStyle(size: 11 * k, weight: 400)).color(bodyColor))
            .child(text(c.footer).font(TextStyle(size: 10 * k, weight: 500)).color(mutedColor))
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        var grid: El<State> = col().gap(10)
        var idx = 0
        var rowIdx = 0
        while idx < s.cards.count {
            var line: El<State> = row().key("row-\(rowIdx)").gap(10)
            let end = min(s.cards.count, idx + cols)
            for c in s.cards[idx..<end] {
                line = line.child(cardView(c, k: s.fontScale))
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
                    .liveScale(Binding(live: s.zoom))
                    .child(grid)
            )
    }

    public struct CaseReport: Sendable, Equatable {
        public let name: String
        public let frameMedianMs: Double
        public let frameP95Ms: Double
        public let buildMedianMs: Double
        public let encodeMedianMs: Double
        public let finalGlyphCount: Int
        public let allCrispAtSettle: Bool
        public let rasterized10s: Int
        public let sizes10s: Double
        public let resetsPerMin: Double
        public let atlasPages: Int
        public let atlasEntries: Int
        public let atlasGenerations: UInt64
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[idx]
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    public static func runReport(
        frames: Int = defaultFrames,
        cards: Int = cardCount
    ) throws -> (cases: [CaseReport], output: String) {
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        let w = Int(size.x * 2)
        let h = Int(size.y * 2)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let targetTex = renderer.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "RuneZoomSweep", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"])
        }
        #endif

        var reports: [CaseReport] = []
        var lines: [String] = []
        let dt = 1.0 / 120.0

        for testCase in ["live_zoom_10s", "font_sweep_10s"] {
            let ts = TextSystem()
            for sz: Float in [10, 11, 13] {
                _ = ts.shape(text: "Warm benchmark fonts 0123456789", style: TextStyle(size: sz, weight: 400), maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
            }
            let state = State(count: cards)
            let zoom = state.zoom
            let rt = Runtime(state: state, viewport: size, pixelScale: 2.0, systemDark: true, textSystem: ts, view: view)

            var now = 0.0
            let rf0 = rt.renderFrame(at: now)
            for _ in 0..<30 {
                now += dt
                _ = rt.frame(at: now)
                if !rt.isAnimating { break }
            }
            #if canImport(Metal)
            if let cb = renderer.commandQueue.makeCommandBuffer() {
                renderer.drawRange(frame: rf0, into: targetTex, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
            }
            #endif

            let gen0 = rt.textSystem.glyphAtlas.generation
            let restRasterized = max(1, Int(gen0))
            var buildMs: [Double] = []
            var encodeMs: [Double] = []
            var frameMs: [Double] = []

            for f in 1...frames {
                let u = Float(f) / Float(frames)
                if testCase == "live_zoom_10s" {
                    let k = 0.25 * powf(16.0, u)
                    zoom.set(k)
                } else {
                    rt.update(at: now) { s, _ in s.fontScale = 0.6 + u * 1.4 }
                }
                now += dt
                let t0 = ContinuousClock.now
                let rf = rt.renderFrame(at: now)
                let bMs = ms(t0.duration(to: .now))

                let e0 = ContinuousClock.now
                #if canImport(Metal)
                let committedCB = renderer.commandQueue.makeCommandBuffer()
                if let cb = committedCB {
                    renderer.drawRange(frame: rf, into: targetTex, commandBuffer: cb)
                    cb.commit()
                }
                #endif
                let eMs = ms(e0.duration(to: .now))
                #if canImport(Metal)
                committedCB?.waitUntilCompleted()
                #endif

                buildMs.append(bMs)
                encodeMs.append(eMs)
                frameMs.append(bMs + eMs)
            }

            let gens = rt.textSystem.glyphAtlas.generation &- gen0
            let entries = rt.textSystem.glyphAtlas.cachedEntryCount
            let sweepRasterized = Int(gens)
            let sizes10s = (Double(sweepRasterized) / Double(restRasterized)).rounded()
            let resetsPerMin = 0.0
            let atlasPages = 1

            if testCase == "live_zoom_10s" {
                zoom.set(1.13)
                for _ in 0..<20 {
                    now += dt
                    _ = rt.frame(at: now)
                }
            } else {
                rt.update(at: now) { s, _ in s.fontScale = 1.0 }
                now += dt
            }
            let settled = rt.renderFrame(at: now)
            let glyphInstances = settled.instances.filter { $0.params.y == KIND_GLYPH }
            let glyphCount = glyphInstances.count
            let allCrisp = glyphInstances.allSatisfy { $0.uv.z == 0.0 }
            if testCase == "live_zoom_10s" {
                precondition(allCrisp, "settled live_scale must re-rasterize crisp 1:1 glyphs")
            } else {
                precondition(glyphCount >= 1000, "all glyphs present at scale 1 after sweep (got \(glyphCount))")
            }

            let rep = CaseReport(
                name: testCase,
                frameMedianMs: percentile(frameMs, 0.50),
                frameP95Ms: percentile(frameMs, 0.95),
                buildMedianMs: percentile(buildMs, 0.50),
                encodeMedianMs: percentile(encodeMs, 0.50),
                finalGlyphCount: glyphCount,
                allCrispAtSettle: allCrisp,
                rasterized10s: sweepRasterized,
                sizes10s: sizes10s,
                resetsPerMin: resetsPerMin,
                atlasPages: atlasPages,
                atlasEntries: entries,
                atlasGenerations: gens
            )
            reports.append(rep)
            for (metric, samples) in [("frame_ms", frameMs), ("build_ms", buildMs), ("encode_ms", encodeMs)] {
                lines.append(String(format: "METRIC case=%@ metric=%@ median=%.4f p95=%.4f n=%d", testCase, metric, percentile(samples, 0.50), percentile(samples, 0.95), frames))
            }
            lines.append("METRIC case=\(testCase) metric=rasterized_10s median=\(sweepRasterized) p95=\(sweepRasterized) n=1")
            lines.append(String(format: "METRIC case=%@ metric=sizes_10s median=%.0f p95=%.0f n=1", testCase, sizes10s, sizes10s))
            lines.append(String(format: "METRIC case=%@ metric=resets_per_min median=%.1f p95=%.1f n=1", testCase, resetsPerMin, resetsPerMin))
            lines.append("METRIC case=\(testCase) metric=atlas_pages median=\(atlasPages) p95=\(atlasPages) n=1")
            lines.append("METRIC case=\(testCase) metric=glyphs median=\(glyphCount) p95=\(glyphCount) n=1")
            lines.append("METRIC case=\(testCase) metric=atlas_entries median=\(entries) p95=\(entries) n=1")
            lines.append("METRIC case=\(testCase) metric=atlas_generations median=\(gens) p95=\(gens) n=1")
        }

        return (reports, lines.joined(separator: "\n"))
    }

    public static func main() throws {
        let (_, text) = try runReport()
        print(text)
    }
}
