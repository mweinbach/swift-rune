import Foundation
import Rune

/// Port of `crates/rune/examples/sticky.rs`.
/// Uses `El.stickyTop(0)`, `El.stuckShadow`, and `Tx.keepOnScreen` for section headers inside
/// a scrollable timeline.
public struct StickyGroup: Sendable {
    public let title: String
    public let badge: String
    public let steps: [(kind: String, detail: String)]
}

public struct StickyState: Sendable {
    public var collapsed: [Bool] = [false, false, false, false]
    public internal(set) var stuckPositions: [Float] = [0, 0, 0, 0]

    public init() {}
}

public enum RuneStickyApp {
    public static let groups: [StickyGroup] = [
        StickyGroup(
            title: "Inspect layout & scroll viewport",
            badge: "5 calls · 120 ms",
            steps: [
                ("read", "crates/rune/src/el.rs (lines 2560–2620)"),
                ("read", "crates/rune/src/runtime.rs (lines 4690–4835)"),
                ("grep", "update_layer_paint_order in crates/rune/src"),
                ("read", "crates/rune/src/scroll_offset.rs (lines 1–96)"),
                ("read", "crates/rune/src/layout_read.rs (lines 1–65)"),
            ]
        ),
        StickyGroup(
            title: "Verify sticky header clamping & push-out",
            badge: "5 calls · 210 ms",
            steps: [
                ("edit", "crates/rune/src/sticky.rs — shift & keep_on_screen"),
                ("edit", "crates/rune/src/runtime.rs — paint pass sticky dy"),
                ("test", "sticky_top_and_bottom_hold_push_out_hit_above_siblings"),
                ("test", "nested_scroll_viewports_stick_each_header"),
                ("test", "virtual_rows_keep_stuck_header_on_screen"),
            ]
        ),
        StickyGroup(
            title: "Audit 120 Hz scroll trace & frame cost",
            badge: "4 calls · 85 ms",
            steps: [
                ("trace", "scripts/motion-audit/analyze.py (0 findings)"),
                ("bench", "50 sticky sections scroll frame CPU"),
                ("snap", "demo/sticky-headers.png"),
                ("check", "scripts/check-reference.sh --gpu"),
            ]
        ),
        StickyGroup(
            title: "Finalize docs & changelog",
            badge: "3 calls · 40 ms",
            steps: [
                ("edit", "crates/rune/README.md — sticky headers section"),
                ("edit", "CHANGELOG.md — ## dev entry"),
                ("test", "cargo test -p rune -p rune-kit"),
            ]
        ),
    ]

    public static func view(state: StickyState, cx: inout Cx<StickyState>) -> El<StickyState> {
        let theme = Tok.theme(dark: true)
        let bg = oklch(0.16, 0.012, 265.0)
        let cardBg = oklch(0.20, 0.014, 265.0)
        let hdrBg = oklch(0.23, 0.018, 265.0)
        let accent = oklch(0.72, 0.14, 250.0)
        let border = Color.white.alpha(0.08)

        let divider = Shadow(x: 0, y: 1, blur: 0, spread: 0, color: Color.white.alpha(0.11))
        let drop = Shadow(x: 0, y: 6, blur: 14, spread: 0, color: Color.black.alpha(0.45))

        var timeline: El<StickyState> = col().key("timeline").wFull().py(8).gap(10)
        for (i, g) in groups.enumerated() {
            let collapsed = i < state.collapsed.count ? state.collapsed[i] : false
            let chevron = collapsed ? "▸" : "▾"
            let hdrKey = "hdr-\(i)"
            let header: El<StickyState> = row()
                .key(hdrKey)
                .wFull()
                .h(38)
                .px(16)
                .gap(8)
                .itemsCenter()
                .bg(hdrBg)
                .stickyTop(0)
                .stuckShadow(divider)
                .stuckShadow(drop)
                .onDrawnLayout { state, rect in state.stuckPositions[i] = rect[1] }
                .onClick { s, tx in
                    if i < s.collapsed.count {
                        s.collapsed[i].toggle()
                        tx.keepOnScreen(hdrKey)
                    }
                }
                .child(text(chevron).font(TextStyle(size: 13, weight: 600)).color(accent))
                .child(text(g.title).font(TextStyle(size: 13, weight: 600)).color(theme.text).grow(1))
                .child(text(g.badge).font(Tok.Typography.label).color(theme.textSecondary))

            var section: El<StickyState> = col()
                .key("sec-\(i)")
                .wFull()
                .pb(6)
                .child(header)

            if !collapsed {
                var body: El<StickyState> = col().key("body-\(i)").wFull().px(16).pt(10).gap(8)
                for (k, step) in g.steps.enumerated() {
                    let rowEl: El<StickyState> = row()
                        .key("step-\(i)-\(k)")
                        .wFull()
                        .h(34)
                        .px(12)
                        .gap(10)
                        .itemsCenter()
                        .rounded(8)
                        .bg(cardBg)
                        .border(1, border)
                        .child(text(step.kind).font(TextStyle(size: 11, weight: 600).mono()).color(accent))
                        .child(text(step.detail).font(TextStyle(size: 12, weight: 400).mono()).color(theme.textSecondary))
                    body = body.child(rowEl)
                }
                section = section.child(body)
            }
            timeline = timeline.child(section)
        }

        return col()
            .wFull()
            .hFull()
            .bg(bg)
            .child(
                col()
                    .key("scroll")
                    .wFull()
                    .grow(1)
                    .minH(0)
                    .scroll(stickBottom: false)
                    .child(timeline)
            )
    }

    public static func makeApp() -> App<StickyState> {
        App(title: "Sticky headers", size: Vec2(560, 420), state: StickyState(), view: view)
    }
}

private func benchmarkView(_ sticky: Bool, _: inout Cx<Bool>) -> El<Bool> {
    let divider = Shadow(x: 0, y: 1, blur: 0, spread: 0, color: Color.white.alpha(0.11))
    let sections = (0..<50).map { section in
        let title = String(format: "Tool group %02d · 6 steps", section)
        var header: El<Bool> = row().key("hdr-\(section)").wFull().h(32).px(12)
            .itemsCenter().bg(oklch(0.23, 0.018, 265))
            .child(text(title).font(TextStyle(size: 13, weight: 600)))
        if sticky { header = header.stickyTop(0).stuckShadow(divider) }
        let rows: [El<Bool>] = (0..<6).map { step in
            row().key("row-\(section)-\(step)").wFull().h(28).px(12).itemsCenter()
                .child(text("step \(step): crates/rune/src/runtime.rs").font(TextStyle(size: 12, weight: 400)))
        }
        return col().key("sec-\(section)").wFull().pb(8).child(header).children(rows)
    }
    let list: El<Bool> = col().key("list").wFull().children(sections)
    return col().wFull().hFull()
        .child(col().key("scroll").wFull().hFull().scroll(stickBottom: false).child(list))
}

private func runBenchmark() {
    let clock = ContinuousClock()
    let center = Vec2(320, 240)
    let dt = 1.0 / 120.0
    for (label, sticky) in [("plain_50_sections", false), ("sticky_50_sections", true)] {
        let runtime = Rune.Runtime(state: sticky, viewport: Vec2(640, 480), pixelScale: 2,
                                   systemDark: true, view: benchmarkView)
        runtime.frameStep(dt: 0)
        for _ in 0..<60 {
            runtime.wheel(WheelEvent(dy: -40), at: center, now: runtime.nowClock())
            runtime.frameStep(dt: dt)
        }
        runtime.update { _, tx in tx.scrollToY("scroll", 0) }
        runtime.frameStep(dt: dt)

        var samples: [Double] = []
        samples.reserveCapacity(240)
        for step in 0..<240 {
            let dy: Float = step < 120 ? -35 : 35
            let start = clock.now
            runtime.wheel(WheelEvent(dy: dy), at: center, now: runtime.nowClock())
            runtime.frameStep(dt: dt)
            let elapsed = start.duration(to: clock.now).components
            samples.append(Double(elapsed.seconds) * 1e6 + Double(elapsed.attoseconds) / 1e12)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[samples.count * 95 / 100]
        let timings = String(format: "median_us=%.1f p95_us=%.1f", locale: Locale(identifier: "en_US_POSIX"), median, p95)
        print("BENCH case=\(label) frames=\(samples.count) \(timings)")
    }
}

@main
enum RuneStickyMain {
    static func main() throws {
        if CommandLine.arguments.contains("--bench") {
            runBenchmark()
            return
        }
        try RuneStickyApp.makeApp().run()
    }
}
