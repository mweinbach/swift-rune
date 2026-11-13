import Foundation
import Rune
#if canImport(Metal)
import Metal
#endif

/// Parity port of `crates/rune/examples/text_gpu.rs`:
/// Headless rest/zoom text snap & GPU/frame timing benchmark (Atlas vs outlined glyphs).
@main
public enum RuneTextGpuApp {
    public static let paragraph =
        "Windfoil integrates each glyph's outline over the pixel box in closed form, so text that " +
        "zooms, scrolls or turns stays as sharp as text at rest. Quick zephyrs blow, vexing daft Jim; " +
        "0123456789 (){}[] -> => != <= Ag Wa To fi fl ff — “quotes” ‘and’ «more»."

    public static let cjk =
        "文字は輪郭から直接描かれ、拡大しても鮮明です。中文排版测试：汉字笔画清晰度。한국어 글꼴 테스트입니다. نص عربي للاختبار والتجربة"

    public final class State: @unchecked Sendable {
        public let content: String
        public let zoom = Live<Float>(1.0)
        public var scroll: Float = 0.0
        public let lines: Int
        public let fontSize: Float
        public let dark: Bool

        public init(content: String, lines: Int, fontSize: Float = 13.0, dark: Bool) {
            self.content = content
            self.lines = lines
            self.fontSize = fontSize
            self.dark = dark
        }
    }

    private static func grey(_ v: UInt8) -> Color {
        let linear = RefShader.srgbToLinear(Float(v) / 255.0)
        return Color(r: linear, g: linear, b: linear, a: 1.0)
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let bg = s.dark ? grey(0x16) : grey(0xFF)
        let fg = s.dark ? grey(0xED) : grey(0x16)
        var body: El<State> = col().gap(4).wFull()
        for i in 0..<s.lines {
            let style: TextStyle
            switch i % 4 {
            case 0: style = TextStyle(size: s.fontSize, weight: 440)
            case 1: style = TextStyle(size: s.fontSize, weight: 400, family: .monospace)
            case 2: style = TextStyle(size: s.fontSize * 1.25, weight: 600)
            default: style = TextStyle(size: s.fontSize * 0.85, weight: 400)
            }
            body = body.child(text(s.content).font(style).color(fg).wFull())
        }
        return el()
            .wFull()
            .hFull()
            .bg(bg)
            .p(16)
            .child(
                el()
                    .key("canvas")
                    .wFull()
                    .liveScale(Binding(live: s.zoom))
                    .offset(0, -s.scroll)
                    .child(body)
            )
    }

    public static func smoothing(named name: String) -> FontSmoothing {
        let target = name.lowercased()
        return FontSmoothing.all.first { $0.rawValue.lowercased() == target } ?? .windfoil
    }

    public static func outlinedCount(_ frame: RenderFrame) -> Int {
        frame.instances.filter { $0.params.y == KIND_GLYPH && $0.radii.w > 0.0 }.count
    }

    public struct SnapSummary: Sendable, Equatable {
        public let writtenFiles: Int
        public let totalGlyphs: Int
    }

    public static func runSnap(
        directory: URL,
        scale: Float = 1.0,
        cjk: Bool = false,
        smoothingName: String? = nil,
        scales: [Float] = [1.0, 1.06, 1.3, 1.6, powf(2.0, 0.25), sqrtf(2.0)]
    ) throws -> SnapSummary {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        #endif
        var written = 0
        var totalGlyphs = 0
        let size = Vec2(520, 300)
        let dt = 1.0 / 120.0

        for dark in [false, true] {
            let state = State(content: cjk ? Self.cjk : Self.paragraph, lines: 4, dark: dark)
            let rt = Runtime(state: state, viewport: size, pixelScale: scale, systemDark: dark, textSystem: TextSystem(), view: view)
            if let smoothingName {
                rt.fontSmoothing = smoothing(named: smoothingName)
            }
            let zoom = state.zoom
            let tag = dark ? "dark" : "light"

            var now = 0.0
            let restFrame = rt.renderFrame(at: now)
            totalGlyphs += restFrame.instances.filter { $0.params.y == KIND_GLYPH }.count
            #if canImport(Metal)
            let restImg = try renderer.renderOffscreen(restFrame)
            try restImg.writePNG(to: directory.appendingPathComponent("rest-\(tag).png"))
            written += 1
            #endif

            for (i, k) in scales.enumerated() {
                zoom.set(k)
                now += dt
                let moving = rt.renderFrame(at: now)
                #if canImport(Metal)
                let movingImg = try renderer.renderOffscreen(moving)
                try movingImg.writePNG(to: directory.appendingPathComponent("zoom\(i)-moving-\(tag).png"))
                written += 1
                #endif

                for _ in 0..<40 {
                    now += dt
                    _ = rt.frame(at: now)
                }
                let resting = rt.renderFrame(at: now)
                #if canImport(Metal)
                let restingImg = try renderer.renderOffscreen(resting)
                try restingImg.writePNG(to: directory.appendingPathComponent("zoom\(i)-rest-\(tag).png"))
                written += 1
                #endif
            }
        }
        return SnapSummary(writtenFiles: written, totalGlyphs: totalGlyphs)
    }

    public struct PerfMetric: Sendable, Equatable {
        public let name: String
        public let medianMs: Double
        public let p90Ms: Double
        public let outlineGlyphs: Int
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    public static func runPerf(
        scale: Float = 1.5,
        mode: String? = nil,
        frames: Int = 220,
        warmup: Int = 20
    ) throws -> (glyphs: Int, metrics: [PerfMetric], output: String) {
        let size = Vec2(2560.0 / scale, 1440.0 / scale)
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 2560, height: 1440, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let targetTex = renderer.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "RuneTextGpu", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"])
        }
        #endif

        let lineCount = (mode == "empty") ? 0 : 48
        let state = State(content: paragraph, lines: lineCount, dark: false)
        let rt = Runtime(state: state, viewport: size, pixelScale: scale, systemDark: false, textSystem: TextSystem(), view: view)
        if let mode, mode != "empty" {
            rt.fontSmoothing = smoothing(named: mode)
        }
        let zoom = state.zoom
        var now = 0.0
        let dt = 1.0 / 120.0
        var latest = rt.renderFrame(at: now)
        for _ in 0..<10 {
            now += dt
            latest = rt.renderFrame(at: now)
        }
        let glyphs = latest.instances.filter { $0.params.y == KIND_GLYPH }.count

        func measureCase(_ name: String, step: (Int) -> Void) -> PerfMetric {
            var samples: [Double] = []
            var lastOutlines = 0
            for f in 0..<frames {
                step(f)
                now += dt
                let t0 = ContinuousClock.now
                let rf = rt.renderFrame(at: now)
                #if canImport(Metal)
                if let cb = renderer.commandQueue.makeCommandBuffer() {
                    renderer.drawRange(frame: rf, into: targetTex, commandBuffer: cb)
                    cb.commit()
                    cb.waitUntilCompleted()
                }
                #endif
                let elapsed = ms(t0.duration(to: .now))
                lastOutlines = outlinedCount(rf)
                if f >= warmup {
                    samples.append(elapsed)
                }
            }
            if samples.isEmpty { return PerfMetric(name: name, medianMs: 0, p90Ms: 0, outlineGlyphs: lastOutlines) }
            let sorted = samples.sorted()
            return PerfMetric(
                name: name,
                medianMs: sorted[sorted.count / 2],
                p90Ms: sorted[(sorted.count * 9) / 10],
                outlineGlyphs: lastOutlines
            )
        }

        let still = measureCase("still") { _ in }
        let scroll = measureCase("scroll") { f in
            rt.update(at: now) { s, _ in s.scroll = Float(f % 60) * 3.0 }
        }
        rt.update(at: now) { s, _ in s.scroll = 0.0 }
        let zooming = measureCase("zoom") { f in
            zoom.set(1.0 + 0.25 * abs(sinf(Float(f) * 0.05)))
        }

        let metrics = [still, scroll, zooming]
        let lines = metrics.map { m in
            String(format: "METRIC case=%@ scale=%.2f mode=%@ median_ms=%.4f p90_ms=%.4f outline_glyphs=%d", m.name, scale, mode ?? "default", m.medianMs, m.p90Ms, m.outlineGlyphs)
        }
        return (glyphs, metrics, lines.joined(separator: "\n"))
    }

    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "snap":
            let dir = URL(fileURLWithPath: args.dropFirst().first ?? "/tmp/rune-text-gpu")
            let scale = args.dropFirst(2).first.flatMap(Float.init) ?? 1.0
            let summary = try runSnap(directory: dir, scale: scale, cjk: args.contains("cjk"))
            print("snap wrote \(summary.writtenFiles) files (rest glyphs=\(summary.totalGlyphs))")
        case "perf":
            let scale = args.dropFirst().first.flatMap(Float.init) ?? 1.5
            let mode = args.dropFirst(2).first
            let (_, _, out) = try runPerf(scale: scale, mode: mode)
            print(out)
        default:
            print("usage: rune-text-gpu snap <dir> [scale] | perf [scale] [mode]")
        }
    }
}
