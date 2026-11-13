import Foundation
import Rune
import RuneKit
import RuneMotion

public struct MotionBentoState: Sendable {
    public var config: ChaosConfig
    public var m: ChaosModel
    public var springs: ChaosSprings
    public var ring: Live<Vec2>
    public var kit: Kit
    public var player: ChaosPlayer?
    public var hud: Bool
    public var hudLines: [String]
    public var hudAt: Double
    public var begun: Bool = false
    public var ended: Bool = false
    public var written: Bool = false
    public var wall: ChaosWall?
    public var t: Double = 0.0
    public var replay: ChaosReplay?
    public var readout: ChaosReadout?
    public var meter: ChaosMeter?
    public let memoCache: MemoCache

    public init(config: ChaosConfig = ChaosConfig(), scripted: Bool = false, meter: ChaosMeter? = nil) {
        let model = ChaosModel(seed: config.seed)
        var kit = Kit.neutral(dark: true)
        kit.c.bgAccent = bentoColor(ChaosColor.accent)
        self.config = config
        self.m = model
        self.springs = ChaosSprings.variant(config.variant)
        self.ring = Live(Vec2(0.0, model.tempFraction()))
        self.kit = kit
        self.player = (!scripted && config.load == nil) ? ChaosPlayer(config: config) : nil
        self.hud = config.hud
        self.hudLines = Array(repeating: "", count: 4)
        self.hudAt = -.infinity
        self.wall = config.load != nil ? ChaosWall(seed: config.seed) : nil
        self.replay = config.hudFrom.flatMap { path in try? ChaosReplay.load(path: path) }
        self.meter = meter
        self.memoCache = MemoCache()
    }

    public mutating func act(_ action: ChaosAction) {
        m.apply(action)
        ring.set(Vec2(0.0, m.tempFraction()))
    }

    public mutating func writeMetrics() {
        guard !written else { return }
        written = true
        guard var meter else { return }
        meter.end()
        if let path = config.frames {
            try? meter.framesCSV().write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = config.metrics {
            try? meter.json().write(toFile: path, atomically: true, encoding: .utf8)
        }
        self.meter = meter
    }
}

public func bentoPoll(_ s: inout MotionBentoState, _ t: Double, _ tx: inout Tx) -> Bool {
    var changed = false
    if var p = s.player {
        let due = p.due(at: t)
        if let next = p.nextAt {
            tx.wakeAfter(max(0.0, next - t))
        }
        s.player = p
        for event in due {
            s.act(event.action)
            changed = true
        }
    }
    if var wall = s.wall, let load = s.config.load {
        let n = load.at(t)
        wall.update(t: t, n: n)
        s.wall = wall
        s.t = t
        s.meter?.tag(show: t, load: n)
        if s.hud {
            if let replay = s.replay {
                s.readout = ChaosReadout.replay(replay, at: t)
            } else if let m = s.meter {
                s.readout = ChaosReadout.live(m)
            }
        }
        tx.wakeAfter(0.0)
        changed = true
    }
    if !s.begun && t >= ChaosSchedule.start {
        s.begun = true
        s.meter?.begin()
    }
    if !s.ended && t >= s.config.duration {
        s.ended = true
        s.meter?.end()
    }
    let headless = CommandLine.arguments.dropFirst().contains {
        $0 == "--snap" || $0 == "--tree" || $0 == "--script" || $0 == "--list-scenes" || $0 == "--headless"
    }
    if !headless && !s.config.stay {
        if t >= s.config.duration + 1.0 {
            s.writeMetrics()
            tx.requestQuit()
        } else if s.ended || t >= s.config.duration {
            tx.wakeAfter(max(0.0, s.config.duration + 1.0 - t))
        }
    }
    if headless && t >= s.config.duration + 1.0 {
        s.writeMetrics()
    }
    if s.hud && s.wall == nil && !headless && t - s.hudAt >= 0.25 {
        s.hudAt = t
        if let m = s.meter {
            let summary = m.recent()
            let lines = [
                String(format: "Rune · %.1f fps · %.1f ms p50", summary.fps, summary.workMs[0]),
                String(format: "build %.1f ms p95 · late %d · drop %d", summary.buildMs?[1] ?? summary.workMs[1], summary.late, summary.dropped),
                String(format: "cpu %.1f%% · mem %.1f MB", summary.cpuPercent, summary.footprintMb),
                "seed \(s.config.seed) · \(s.config.variant)",
            ]
            if lines != s.hudLines {
                s.hudLines = lines
                changed = true
            }
        }
        tx.wakeAfter(0.25)
    }
    return changed
}

private func bentoHeader(_ s: MotionBentoState) -> El<MotionBentoState> {
    let k = s.kit
    let mood = ChaosColor.scene[s.m.scene]
    let scene: El<MotionBentoState> = row()
        .h(34.0)
        .px(14.0)
        .gap(8.0)
        .rounded(17.0)
        .centerY()
        .bg(bentoColor(ChaosColor.tile))
        .border(1.0, bentoColor(ChaosColor.edge))
        .animateLayout(bentoSpring(s.springs.layout))
        .child(
            el()
                .size(10.0, 10.0)
                .rounded(5.0)
                .bg(bentoColor(mood))
                .animate(bentoSpring(s.springs.morph))
        )
        .child(
            k.rollingText(
                key: "head-scene",
                ChaosConstants.scenes[s.m.scene],
                font: bentoFont(13.0, 560.0),
                color: bentoColor(ChaosColor.text)
            )
        )

    let events = row()
        .gap(6.0)
        .centerY()
        .child(
            k.rollingText(
                key: "events",
                "\(s.m.events)",
                font: bentoNums(13.0, 600.0),
                color: bentoColor(ChaosColor.text)
            )
        )
        .child(bentoCaption("events"))

    return row()
        .wFull()
        .h(ChaosGrid.header)
        .centerY()
        .gap(16.0)
        .child(
            col()
                .gap(2.0)
                .child(text("Studio").font(bentoFont(24.0, 680.0)).color(bentoColor(ChaosColor.text)))
                .child(bentoCaption("Control center · Friday evening"))
        )
        .child(spacer())
        .child(events)
        .child(scene)
}

private func bentoHud(_ s: MotionBentoState) -> El<MotionBentoState> {
    var lines: El<MotionBentoState> = col()
        .key("hud")
        .absolute(x: ChaosGrid.width - ChaosGrid.pad - 300.0, y: 12.0)
        .w(300.0)
        .p(12.0)
        .gap(3.0)
        .rounded(12.0)
        .bg(bentoColor(ChaosColor.bg.alpha(0.92)))
        .border(1.0, bentoColor(ChaosColor.accent.alpha(0.4)))
        .z(1)
    for line in s.hudLines {
        let label: El<MotionBentoState> = text(line).font(bentoNums(11.0, 500.0).mono()).color(bentoColor(ChaosColor.text2))
        lines = lines.child(label)
    }
    return lines
}

public func bentoView(_ s: MotionBentoState, _ cx: inout Cx<MotionBentoState>) -> El<MotionBentoState> {
    if let wall = s.wall {
        return bentoStressView(s, wall)
    }
    let k = s.kit
    let m = s.m
    let headerEl = memo("header", deps: [UInt32(m.scene), m.events], cache: s.memoCache) {
        bentoHeader(s)
    }
    let sceneEl = memo(
        "scene",
        deps: [UInt32(m.scene), m.temp.bitPattern] + m.lights.map { $0 ? 1 : 0 } + m.chips.map { $0 ? 1 : 0 },
        cache: s.memoCache
    ) {
        bentoScenes(s, k)
    }
    let thermoEl = memo("thermo", deps: m.temp.bitPattern, cache: s.memoCache) {
        bentoThermostat(s, k)
    }
    let lightsEl = memo("lights", deps: m.lights, cache: s.memoCache) {
        bentoLights(s, k)
    }
    let mixerEl = memo("mixer", deps: m.faders.map(\.bitPattern), cache: s.memoCache) {
        bentoMixer(s, k)
    }
    let xyEl = memo("xy", deps: m.puck.map(\.bitPattern), cache: s.memoCache) {
        bentoXY(s, k)
    }
    let queueEl = memo("queue", deps: m.queue, cache: s.memoCache) {
        bentoQueue(s, k)
    }
    let feedEl = memo("feed", deps: m.feed, cache: s.memoCache) {
        bentoFeed(s, k)
    }

    var root = col()
        .w(ChaosGrid.width)
        .h(ChaosGrid.height)
        .px(ChaosGrid.pad)
        .pb(ChaosGrid.pad)
        .pt(ChaosGrid.pad - 8.0)
        .gap(ChaosGrid.gap)
        .bg(bentoColor(ChaosColor.bg))
        .animateLayout(bentoSpring(s.springs.layout))
        .child(headerEl)
        .child(
            row()
                .h(ChaosGrid.row1)
                .gap(ChaosGrid.gap)
                .child(sceneEl)
                .child(thermoEl)
                .child(lightsEl)
        )
        .child(
            row()
                .h(ChaosGrid.row2)
                .gap(ChaosGrid.gap)
                .child(mixerEl)
                .child(xyEl)
                .child(queueEl)
                .child(feedEl)
        )
        .child(bentoDock(s, k))

    if s.hud {
        root = root.child(bentoHud(s))
    }
    return root
}

private final class SharedMeterBox: @unchecked Sendable {
    let lock = NSLock()
    var meter: ChaosMeter
    init(_ meter: ChaosMeter) { self.meter = meter }
}

@main
public enum RuneMotionBentoApp {
    public static func makeApp(
        config: ChaosConfig = ChaosConfig(),
        arguments: [String] = []
    ) -> App<MotionBentoState> {
        let scripted = arguments.contains("--script")
        var meter = ChaosMeter(framework: "rune", refreshHz: 120.0)
        meter.note("work", "update_ms + encode_ms: events, poll, view, layout, paint, upload and encode, to submit")
        meter.note("build", "update_ms: events, poll, view, layout and paint")
        meter.note("variant", config.variant)
        meter.note("seed", "\(config.seed)")
        meter.note("mode", config.naive ? "naive" : "idiomatic")
        let sharedMeter = SharedMeterBox(meter)

        return App<MotionBentoState>(
            title: "Motion bento",
            size: Vec2(ChaosGrid.width, ChaosGrid.height),
            minSize: Vec2(ChaosGrid.width, ChaosGrid.height),
            dark: true,
            state: MotionBentoState(config: config, scripted: scripted, meter: meter),
            view: bentoView
        )
        .args(RunOptions(arguments: arguments))
        .poll { state, t, tx in
            sharedMeter.lock.lock()
            state.meter = sharedMeter.meter
            sharedMeter.lock.unlock()
            let changed = bentoPoll(&state, t, &tx)
            if let updated = state.meter {
                sharedMeter.lock.lock()
                sharedMeter.meter = updated
                sharedMeter.lock.unlock()
            }
            return changed
        }
        .onKey { state, event, _ in
            if case .text(let t) = event.key, t.lowercased() == "h" {
                state.hud.toggle()
                state.readout = nil
                state.hudAt = -.infinity
                return true
            }
            return false
        }
        .onClose { state, _ in
            state.writeMetrics()
            return true
        }
        .onFrameEncoded { frame in
            guard frame.outcome == .drawn else { return }
            let build = frame.updateMs
            let work = build + frame.encodeMs
            sharedMeter.lock.lock()
            sharedMeter.meter.frameWithBuild(at: ContinuousClock.now, workMs: work, buildMs: build)
            sharedMeter.lock.unlock()
        }
    }

    public static func main() throws {
        do {
            let (cfg, rest) = try ChaosConfig.parse(Array(CommandLine.arguments.dropFirst()))
            if let path = cfg.emitScript {
                try ChaosSchedule.scriptJSON(cfg).write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
            try makeApp(config: cfg, arguments: rest).run()
        } catch {
            fputs("motion-bento: \(error)\n", stderr)
            exit(2)
        }
    }
}
