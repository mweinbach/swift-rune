import Foundation
import Rune
import RuneKit
#if canImport(Darwin)
import Darwin
#endif

/// Parity port of `crates/rune-kit/examples/layout_text_cost`:
/// Profiles cold build, layout, text shaping, paint, scroll, and resize costs
/// for heavy Markdown + RuneKit UI scenes (Card, Badge, Switch, Button, MarkdownView).
@main
public enum RuneKitLayoutTextCostApp {
    public struct State: Sendable {
        public var markdown: String
        public var width: Float
        public var toggle: Bool = true
        public var style: MarkdownStyle
        public var kit: Kit

        public init(markdown: String, width: Float = 960, dark: Bool = true) {
            self.markdown = markdown
            self.width = width
            let kit = Kit.neutral(dark: dark)
            self.kit = kit
            self.style = MarkdownStyle.fromKit(kit)
        }
    }

    public struct CaseMetric: Sendable, Equatable {
        public let name: String
        public let wallMs: Double
        public let cpuMs: Double
        public let layoutMs: Double
        public let textMs: Double
        public let instances: Int
        public let glyphs: Int
    }

    public struct Report: Sendable {
        public let cases: [CaseMetric]
        public let footprintMB: Double
        public let output: String
    }

    public static func generateDocument(bytes: Int) -> String {
        let words = [
            "amber", "lantern", "harbor", "meadow", "signal", "copper", "willow",
            "pebble", "cinder", "glacier", "juniper", "kestrel", "lumen", "nimbus",
        ]
        var out = "# Layout & Text Cost Corpus\n\n"
        var idx = 0
        while out.utf8.count < bytes {
            idx += 1
            let w0 = words[idx % words.count]
            let w1 = words[(idx + 3) % words.count]
            out += "## Section \(idx): `\(w0)` & **\(w1)**\n\n"
            out += "The \(w0) passes through the [\(w1)](https://example.com/\(w1)) corridor while "
            out += "tracking layout passes, *glyph caching*, and line breaks across \(idx * 17) entries.\n\n"
            out += "- [x] Measure \(w0) paragraph\n- [ ] Measure \(w1) table cell\n\n"
            out += "| Metric | Value |\n| --- | --- |\n| \(w0) | \(idx * 11) ms |\n\n"
        }
        return out
    }

    private static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let k = s.kit
        let md = MarkdownView<State>(s.markdown).render(s.style)
        let headerCard = Card<State>()
            .title("Document Summary")
            .description("Markdown + Kit widgets stress case")
            .action(Badge("LIVE").variant(.accent).build(k))
            .child(
                row().gap(8).itemsCenter()
                    .child(Switch<State>(checked: s.toggle).label("Wrap").onToggle { $0.toggle.toggle() }.build(k))
                    .child(k.button(key: "refresh", "Refresh", variant: .neutral) { _, _ in })
            )
            .build(k)

        return col()
            .wFull()
            .hFull()
            .bg(k.c.bgBase)
            .child(
                col()
                    .key("viewport")
                    .wFull()
                    .grow(1)
                    .minH(0)
                    .scroll(stickBottom: false)
                    .px(24)
                    .py(18)
                    .gap(12)
                    .child(headerCard)
                    .child(md)
            )
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    }

    private static func residentMB() -> Double {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Double(info.phys_footprint) / 1_048_576.0
        }
        #endif
        return 0
    }

    public static func runReport(bytes: Int = 16_000, resizeSteps: Int = 8, scrollFrames: Int = 10) -> Report {
        var cases: [CaseMetric] = []
        var lines: [String] = []
        let doc = generateDocument(bytes: bytes)

        func measureCase(_ name: String, _ work: () -> (instances: Int, glyphs: Int)) {
            _ = takeFramePhases()
            let t0 = ContinuousClock.now
            let c0 = threadCpuMs()
            let counts = work()
            let cpu = threadCpuMs() - c0
            let wall = ms(t0.duration(to: .now))
            let phases = takeFramePhases()
            let layoutMs = phases.count > 8 ? phases[8] : 0
            let textMs = phases.count > 9 ? phases[9] : 0
            let m = CaseMetric(
                name: name,
                wallMs: wall,
                cpuMs: cpu,
                layoutMs: layoutMs,
                textMs: textMs,
                instances: counts.instances,
                glyphs: counts.glyphs
            )
            cases.append(m)
            lines.append(String(
                format: "CASE name=%@ wall_ms=%.3f cpu_ms=%.3f layout_ms=%.3f text_ms=%.3f instances=%d glyphs=%d",
                name, wall, cpu, layoutMs, textMs, counts.instances, counts.glyphs
            ))
        }

        let rt = Runtime(
            state: State(markdown: doc),
            viewport: Vec2(960, 720),
            pixelScale: 2.0,
            systemDark: true,
            view: view
        )
        var now = 0.0

        func counts(of rf: RenderFrame) -> (instances: Int, glyphs: Int) {
            (rf.instances.count, rf.instances.reduce(0) { $0 + ($1.params.y == KIND_GLYPH ? 1 : 0) })
        }

        measureCase("open_cold") {
            counts(of: rt.renderFrame(at: now))
        }

        measureCase("resize_sweep") {
            var last = (0, 0)
            for i in 0..<resizeSteps {
                let w: Float = 960 - Float(i * 25)
                rt.setViewport(Vec2(w, 720))
                now += 1.0 / 120.0
                last = counts(of: rt.renderFrame(at: now))
            }
            return last
        }

        measureCase("scroll_sweep") {
            var last = (0, 0)
            for _ in 0..<scrollFrames {
                rt.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(480, 360), now: now)
                now += 1.0 / 120.0
                last = counts(of: rt.renderFrame(at: now))
            }
            return last
        }

        let mb = residentMB()
        lines.append(String(format: "MEMORY footprint_mb=%.2f", mb))
        return Report(cases: cases, footprintMB: mb, output: lines.joined(separator: "\n"))
    }

    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let bytes = args.firstIndex(of: "--bytes").flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } ?? 32_000
        let report = runReport(bytes: bytes, resizeSteps: 20, scrollFrames: 24)
        print(report.output)
    }
}
