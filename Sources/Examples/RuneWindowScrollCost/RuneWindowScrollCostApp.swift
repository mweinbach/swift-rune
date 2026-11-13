import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/window_scroll_cost.rs`.
@main
public enum RuneWindowScrollCostApp {
    public struct State: Sendable {
        public var rows: Int
        public var selected: Int? = nil
        public init(rows: Int = 240) {
            self.rows = rows
        }
    }

    public struct Report: Sendable {
        public let frames: Int
        public let instances: Int
        public let usPerFrame: Double
        public let scrollOffset: Float
        public let output: String
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let items = (0..<s.rows).map { i -> El<State> in
            let active = s.selected == i
            return row()
                .key("row-\(i)")
                .wFull()
                .h(38)
                .px(12)
                .itemsCenter()
                .justifyBetween()
                .rounded(6)
                .bg(active ? oklch(0.32, 0.08, 250) : Color.white.alpha(i % 2 == 0 ? 0.05 : 0.025))
                .onClick { st in st.selected = i }
                .child(text("Window scroll item #\(i)").font(TextStyle(size: 13, weight: 500)).color(.white))
                .child(text("delta \(i * 17)").font(TextStyle(size: 11, weight: 400)).color(Color.white.alpha(0.5)))
        }
        return col()
            .wFull()
            .hFull()
            .bg(Color.rgba8(0x0c, 0x0c, 0x0e))
            .child(
                col()
                    .key("scroll-body")
                    .wFull()
                    .grow(1)
                    .minH(0)
                    .scroll(stickBottom: false)
                    .p(12)
                    .gap(4)
                    .children(items)
            )
    }

    public static func makeApp() -> App<State> {
        App(title: "window_scroll_cost", state: State()) { s, cx in view(s, &cx) }
            .size(720, 560)
    }

    public static func runBench(rows: Int = 120, frames: Int = 24) -> Report {
        let rt = App(title: "window_scroll_cost", state: State(rows: rows)) { s, cx in view(s, &cx) }
            .size(720, 560)
            .makeRuntime(viewport: Vec2(720, 560), pixelScale: 2.0, systemDark: true)
        var now = 0.0
        _ = rt.renderFrame(at: now)
        let cpu0 = threadCpuMs()
        var lastInstances = 0
        for _ in 0..<frames {
            now += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -64), at: Vec2(360, 280), now: now)
            let rf = rt.renderFrame(at: now)
            lastInstances = rf.instances.count
        }
        let cpuUs = max(0, threadCpuMs() - cpu0) * 1e3 / Double(max(1, frames))
        let offset = rt.scrollOffset(forKey: "scroll-body").y
        let out = String(format: "window_scroll_cost frames=%d instances=%d cpu_us=%.1f scroll_y=%.1f",
                         frames, lastInstances, cpuUs, offset)
        return Report(frames: frames, instances: lastInstances, usPerFrame: cpuUs, scrollOffset: offset, output: out)
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--bench") || args.contains("--headless") {
            let report = runBench()
            print(report.output)
            return
        }
        try makeApp().run()
    }
}
