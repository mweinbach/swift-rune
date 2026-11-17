import Foundation
import Rune
import RunePerf
#if canImport(Metal)
import Metal
#endif

public struct PinchCanvasState: Sendable {
    public var live: Bool
    public var cards: Int
    public var zoom: Float = 1.0
    public var pan: Vec2 = .zero
    public var camPan: Live<Vec2> = Live(.zero)
    public var camZoom: Live<Float> = Live(1.0)
    /// Where the toolbar shows: read by the view (`rebuild`) or set live (`live`).
    public var toolbar: Vec2 = .zero
    public var toolbarLive: Live<Vec2> = Live(.zero)
    public var liveOnlyEvents: Int = 0

    public init(live: Bool = false, cards: Int = 2000) {
        self.live = live
        self.cards = max(1, cards)
    }

    /// Zooms by `1 + delta` about canvas point `(x, y)`; the camera scales about the canvas centre.
    public mutating func zoomAbout(x: Float, y: Float, delta: Float) {
        let cx = RunePinchBenchApp.size.x * 0.5
        let cy = RunePinchBenchApp.size.y * 0.5
        let z = min(max(zoom * (1.0 + delta), 0.05), 8.0)
        let k = z / zoom
        pan = Vec2(
            x - cx - (x - cx - pan.x) * k,
            y - cy - (y - cy - pan.y) * k
        )
        zoom = z
        camPan.set(pan)
        camZoom.set(z)
    }
}

@main
public enum RunePinchBenchApp {
    public static let size = Vec2(1200.0, 800.0)
    public static let columns = 50
    public static let frames = 120
    public static let selected = 7
    public static let metrics = [
        "commits",
        "cpu_ms",
        "frame_ms",
        "encode_ms",
        "view_ms",
        "layout_ms",
        "allocations",
        "live_only_events",
    ]

    public static func card(_ i: Int) -> El<PinchCanvasState> {
        let x = 24.0 + 220.0 * Float(i % columns)
        let y = 24.0 + 140.0 * Float(i / columns)
        return el()
            .key("card\(i)")
            .pin(top: y, left: x)
            .size(200.0, 120.0)
            .rounded(10.0)
            .bg(Color.white.alpha(0.08))
            .p(12.0)
            .child(text("Frame \(i)").font(TextStyle(size: 15.0, weight: 600.0)))
            .child(text("\(200 + i % 7) × \(120 + i % 5)").font(TextStyle(size: 12.0, weight: 400.0)))
    }

    public static func view(_ s: PinchCanvasState, _ cx: inout Cx<PinchCanvasState>) -> El<PinchCanvasState> {
        _ = cx
        var world: El<PinchCanvasState> = el()
            .key("world")
            .size(size.x, size.y)
            .liveOffset(s.camPan.binding)
            .liveScale(s.camZoom.binding)

        for i in 0..<s.cards {
            let c = card(i)
            if i == selected {
                world = world.child(
                    c.onDrawnLayoutTx { state, r, tx in
                        let at = Vec2(r[0] + r[2] * 0.5 - 60.0, r[1] - 40.0)
                        if state.live {
                            state.toolbarLive.set(at)
                            state.liveOnlyEvents &+= 1
                            tx.liveOnly()
                        } else {
                            state.toolbar = at
                        }
                    }
                )
            } else {
                world = world.child(c)
            }
        }

        let at = s.live ? Vec2.zero : s.toolbar
        var toolbar: El<PinchCanvasState> = el()
            .key("toolbar")
            .pin(top: at.y, left: at.x)
            .size(120.0, 32.0)
            .rounded(8.0)
            .bg(.white)
        if s.live {
            toolbar = toolbar.liveOffset(s.toolbarLive.binding)
        }

        return el()
            .key("canvas")
            .size(size.x, size.y)
            .clipSoft(0.0)
            .child(world)
            .child(toolbar)
            .onMagnify { state, ev, tx in
                state.zoomAbout(x: ev.x, y: ev.y, delta: ev.delta)
                if state.live {
                    state.liveOnlyEvents &+= 1
                    tx.liveOnly()
                }
                return true
            }
    }

    public struct MetricLine: Sendable, Equatable {
        public let mode: String
        public let cards: Int
        public let metric: String
        public let median: Double
        public let p95: Double
        public let count: Int
    }

    public static func runReport(
        samples: Int = 9,
        cards: Int = 2000,
        frames overrideFrames: Int = frames
    ) throws -> (lines: [MetricLine], output: String) {
        let frameCount = max(1, overrideFrames)
        #if canImport(Metal)
        let renderer = try MetalRenderer()
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.x * 2.0),
            height: Int(size.y * 2.0),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        guard let targetTex = renderer.device.makeTexture(descriptor: desc) else {
            throw NSError(
                domain: "RunePinchBench",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate offscreen Metal texture"]
            )
        }

        func runSample(live: Bool) -> [Double] {
            let state = PinchCanvasState(live: live, cards: cards)
            let rt = Runtime<PinchCanvasState>(
                state: state,
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
            let warmRf = rt.renderFrame(at: now)
            if let cb = renderer.commandQueue.makeCommandBuffer() {
                renderer.drawRange(frame: warmRf, into: targetTex, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
            }
            _ = takeFramePhases()
            let commits0 = rt.viewCommitCount
            let live0 = rt.state.liveOnlyEvents

            var cpu = 0.0
            var frame = 0.0
            var encode = 0.0
            var allocations = 0.0

            for i in 0..<frameCount {
                let delta: Float = (i < frameCount / 2) ? 0.01 : -0.01
                now += 1.0 / 120.0
                let alloc0 = ProcessCountingAllocator.shared.threadAllocations()
                let cpu0 = threadCpuMs()
                _ = rt.magnify(MagnifyEvent(delta: delta, x: 400.0, y: 300.0), at: Vec2(400.0, 300.0), now: now)
                let rf = rt.renderFrame(at: now)
                let cpu1 = threadCpuMs()
                let committedCB = renderer.commandQueue.makeCommandBuffer()
                if let cb = committedCB {
                    renderer.drawRange(frame: rf, into: targetTex, commandBuffer: cb)
                    cb.commit()
                }
                let cpu2 = threadCpuMs()
                allocations += Double(max(0, Int64(ProcessCountingAllocator.shared.threadAllocations()) - Int64(alloc0)))
                committedCB?.waitUntilCompleted()
                frame += max(0.0, cpu1 - cpu0)
                encode += max(0.0, cpu2 - cpu1)
                cpu += max(0.0, cpu2 - cpu0)
            }

            let phases = takeFramePhases()
            let viewCpu = phases.count > (FRAME_PHASES + FramePhase.view.rawValue)
                ? phases[FRAME_PHASES + FramePhase.view.rawValue]
                : 0.0
            let layoutCpu = phases.count > (FRAME_PHASES + FramePhase.layout.rawValue)
                ? phases[FRAME_PHASES + FramePhase.layout.rawValue]
                : 0.0
            let n = Double(frameCount)
            let commits = Double(rt.viewCommitCount - commits0)
            let liveEvents = Double(rt.state.liveOnlyEvents - live0)
            return [
                commits / n,
                cpu / n,
                frame / n,
                encode / n,
                viewCpu / n,
                layoutCpu / n,
                allocations / n,
                liveEvents / n,
            ]
        }

        var rows: [[[Double]]] = [[], []]
        for s in 0...samples {
            let order = (s % 2 == 0) ? [false, true] : [true, false]
            for live in order {
                let r = runSample(live: live)
                if s > 0 {
                    rows[live ? 1 : 0].append(r)
                }
            }
        }

        var outLines: [MetricLine] = []
        var textLines: [String] = []
        for (liveIdx, batch) in rows.enumerated() {
            let mode = (liveIdx == 1) ? "live" : "rebuild"
            for (m, name) in metrics.enumerated() {
                let v = batch.map { $0[m] }.sorted()
                let med = v[v.count / 2]
                let p95 = v[Int((Double(max(1, v.count) - 1) * 0.95).rounded())]
                outLines.append(MetricLine(mode: mode, cards: cards, metric: name, median: med, p95: p95, count: v.count))
                textLines.append(String(
                    format: "METRIC mode=%@ cards=%d metric=%@ median=%.4f p95=%.4f n=%d",
                    mode, cards, name, med, p95, v.count
                ))
            }
        }
        return (outLines, textLines.joined(separator: "\n"))
        #else
        _ = (samples, cards, frameCount)
        return ([], "pinch_bench: Metal unavailable on this platform")
        #endif
    }

    public static func makeApp(cards: Int = 2000) -> App<PinchCanvasState> {
        App<PinchCanvasState>(
            "Pinch Bench",
            size: size,
            init: { PinchCanvasState(live: true, cards: cards) },
            view: view
        )
        .dark(true)
    }

    private static func flagValue(_ name: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let parsed = ToolingArgs.parse(args)
        let cards = flagValue("--cards", in: args).flatMap(Int.init) ?? 2000
        if parsed.isHeadlessRequested {
            try RuneApp.run(makeApp(cards: cards), arguments: args)
            return
        }
        let samples = flagValue("--samples", in: args).flatMap(Int.init) ?? 9
        #if DEBUG
        RuneStandardIO.error("pinch_bench: debug build; time a release build\n")
        #endif
        let report = try runReport(samples: samples, cards: cards)
        print(report.output)
    }
}
