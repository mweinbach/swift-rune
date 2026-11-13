import Foundation
import Rune

/// Port of `crates/rune/examples/sticky.rs`.
/// Uses `El.stickyTop(0)` for section headers inside a scrollable timeline; `stuckShadow` and
/// `Tx.keepOnScreen` will be wired once those modifiers land from `gap/el` and `gap/shell`.
public struct StickyGroup: Sendable {
    public let title: String
    public let badge: String
    public let steps: [(kind: String, detail: String)]
}

public struct StickyState: Sendable {
    public var collapsed: [Bool] = [false, false, false, false]

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

        var timeline: El<StickyState> = col().key("timeline").wFull().py(8).gap(10)
        for (i, g) in groups.enumerated() {
            let collapsed = i < state.collapsed.count ? state.collapsed[i] : false
            let chevron = collapsed ? "▸" : "▾"
            let header: El<StickyState> = row()
                .key("hdr-\(i)")
                .wFull()
                .h(38)
                .px(16)
                .gap(8)
                .itemsCenter()
                .bg(hdrBg)
                .stickyTop(0)
                .onClick { s in
                    if i < s.collapsed.count {
                        s.collapsed[i].toggle()
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
        App(title: "Sticky headers", size: Vec2(440, 380), state: StickyState(), view: view)
    }
}

@main
enum RuneStickyMain {
    static func main() throws {
        try RuneStickyApp.makeApp().run()
    }
}
