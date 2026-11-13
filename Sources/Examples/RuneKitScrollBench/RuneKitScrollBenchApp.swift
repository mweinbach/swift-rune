import Foundation
import Rune
import RuneKit

/// Parity port of `crates/rune-kit/examples/scroll_bench.rs`:
/// Benchmarks deterministic scroll workloads (`list`, `markdown`, `sticky`, `growth`, `prose`, `card`)
/// across frame phases and rebuild counts.
/// Note: `"card"` builds the entry card layout faithfully without `onDrawnLayout` / `hoverMotionWithin`
/// (pending `@el` Increment 5 `#441`).
@main
public enum RuneKitScrollBenchApp {
    public static let size = Vec2(960, 720)
    public static let prose =
        "Amber lantern orchard quiet harbor, copper meadow signal drift. Pebble willow " +
        "ember tide under a juniper kestrel; nimbus opal prism and a quiet harbor beneath the lantern. "

    public final class ViewCounter: @unchecked Sendable {
        public var builds: Int = 0
    }

    public struct State: @unchecked Sendable {
        public var workload: String
        public var rows: Int
        public var source: String
        public var notes: [String]
        public var marker: Int
        public var style: MarkdownStyle
        public let views = ViewCounter()

        public init(workload: String, rows: Int = 200) {
            self.workload = workload
            self.rows = rows
            self.style = MarkdownStyle.fromKit(Kit.neutral(dark: true))
            var md = ""
            for i in 0..<40 {
                md += "## Section \(i)\n\n"
                md += "\(prose)\(prose)\n\n- First **bold** item\n- Second `inline` item\n\n"
            }
            self.source = md
            self.notes = (0..<24).map { i in
                "### Note \(i)\n\n\(prose)\n\n`tag-\(i)` **ready**"
            }
            self.marker = 0
        }
    }

    public struct BenchResult: Sendable, Equatable {
        public let workload: String
        public let frames: Int
        public let viewRebuilds: Int
        public let medianCpuMs: Double
        public let instances: Int
    }

    private static func itemRow(_ i: Int) -> El<State> {
        col()
            .key("row-\(i)")
            .wFull()
            .h(32)
            .hover(Color.white.alpha(0.08))
            .onClick { _ in }
            .child(
                text("Row \(i): amber lantern orchard quiet harbor")
                    .font(TextStyle(size: 14, weight: 400))
                    .color(.white)
            )
    }

    private static func chip(_ label: String, _ i: Int, _ c: Int) -> El<State> {
        row()
            .key("chip-\(i)-\(c)")
            .h(20)
            .px(6)
            .gap(4)
            .itemsCenter()
            .rounded(5)
            .bg(Color.white.alpha(0.08))
            .hover(Color.white.alpha(0.14))
            .onClick { _ in }
            .child(el().size(8, 8).rounded(4).bg(oklch(0.72, 0.12, 245)))
            .child(text(label).font(TextStyle(size: 12, weight: 500)).color(.white))
    }

    private static func entryCard(_ s: State, _ i: Int, _ note: String) -> El<State> {
        let small = TextStyle(size: 12, weight: 400)
        let head = row()
            .key("head")
            .wFull()
            .gap(8)
            .itemsCenter()
            .child(el().size(22, 22).rounded(11).bg(oklch(0.6, 0.14, 295)))
            .child(text("Agent \(i % 7)").font(TextStyle(size: 13, weight: 600)).color(.white))
            .child(text("\(3 + i)m ago").font(small).color(Color.white.alpha(0.5)))
            .child(row().key("chips").gap(4).children((0..<3).map { c in chip("t\(400 + i * 3 + c)", i, c) }))
        let links: El<State> = row()
            .key("links")
            .wFull()
            .gap(6)
            .flexWrap()
            .children((0..<4).map { c in
                text("#\(1000 + i) lantern-\(c)")
                    .key("link-\(c)")
                    .font(small)
                    .color(oklch(0.75, 0.1, 250))
                    .onClick { _ in }
            })
        let fillAlpha: Float = (i == s.marker) ? 0.07 : 0.04
        return col()
            .key("entry-\(i)")
            .wFull()
            .gap(6)
            .p(10)
            .rounded(8)
            .bg(Color.white.alpha(fillAlpha))
            .border(1, Color.white.alpha(0.08))
            .child(head)
            .child(MarkdownView<State>(note).render(s.style).key("note"))
            .child(links)
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        s.views.builds += 1
        let content: El<State>
        switch s.workload {
        case "markdown":
            content = MarkdownView<State>(s.source).render(s.style)
        case "sticky":
            content = col().wFull().children((0..<20).map { section in
                col().key("section-\(section)").wFull()
                    .child(
                        text("Section \(section)")
                            .key("header")
                            .h(32)
                            .wFull()
                            .bg(.black)
                            .color(.white)
                            .stickyTop(0)
                    )
                    .children((0..<12).map { i in itemRow(section * 12 + i) })
            })
        case "growth":
            content = col().key("stack").wFull().growth(.default).children((0..<s.rows).map(itemRow))
        case "list":
            content = col().wFull().children((0..<s.rows).map(itemRow))
        case "prose":
            content = col().wFull().gap(12).p(16).children((0..<80).map { i -> El<State> in
                let repeated = String(repeating: prose, count: 1 + i % 3)
                return text("\(i). \(repeated)")
                    .key("para-\(i)")
                    .font(TextStyle(size: 13, weight: 400))
                    .color(.white)
                    .wFull()
            })
        case "card":
            content = col().wFull().gap(14).p(16)
                .children(s.notes.enumerated().map { entryCard(s, $0.offset, $0.element) })
        default:
            fatalError("Unknown scroll_bench workload: \(s.workload)")
        }

        return col().wFull().hFull().bg(.black).child(
            col()
                .key("viewport")
                .wFull()
                .hFull()
                .scroll(stickBottom: s.workload == "growth")
                .clipFade(top: 12, bottom: 12)
                .child(content)
        )
    }

    public static func runWorkload(
        _ workload: String,
        rows: Int = 200,
        frames: Int = 24,
        fps: Double = 120.0
    ) -> BenchResult {
        let rt = Runtime(
            state: State(workload: workload, rows: rows),
            viewport: size,
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var now = 0.0
        _ = rt.frame(at: now)
        let builds0 = rt.state.views.builds
        var cpus: [Double] = []
        var lastInstances = 0
        for i in 0..<frames {
            let dy: Float = (i < frames / 2) ? -48.0 : 48.0
            now += 1.0 / fps
            let c0 = threadCpuMs()
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(size.x / 2, size.y / 2), now: now)
            let rf = rt.renderFrame(at: now)
            cpus.append(threadCpuMs() - c0)
            lastInstances = rf.instances.count
        }
        let sorted = cpus.sorted()
        let med = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return BenchResult(
            workload: workload,
            frames: frames,
            viewRebuilds: rt.state.views.builds - builds0,
            medianCpuMs: med,
            instances: lastInstances
        )
    }

    public static func runAll(workloads: [String] = ["list", "markdown", "sticky", "growth", "prose", "card"], rows: Int = 120, frames: Int = 16) -> (results: [BenchResult], output: String) {
        let res = workloads.map { runWorkload($0, rows: rows, frames: frames) }
        let out = res.map {
            String(format: "WORKLOAD name=%@ frames=%d rebuilds=%d median_cpu_ms=%.4f instances=%d", $0.workload, $0.frames, $0.viewRebuilds, $0.medianCpuMs, $0.instances)
        }.joined(separator: "\n")
        return (res, out)
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let workload = args.firstIndex(of: "--workload").flatMap { i in i + 1 < args.count ? args[i + 1] : nil }
        let frames = args.firstIndex(of: "--frames").flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } ?? 120
        let list = workload.map { [$0] } ?? ["list", "markdown", "sticky", "growth", "prose", "card"]
        let report = runAll(workloads: list, rows: 200, frames: frames)
        print(report.output)
    }
}
