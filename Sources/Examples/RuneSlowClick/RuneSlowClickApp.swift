import Foundation
import Rune
import RunePerf

/// Parity port of `crates/rune/examples/slow_click.rs`:
/// a settings page with two slow buttons (Save sleeps 40 ms; Sort spins CPU 40 ms) instrumented via `PerfRecorder`.
@main
enum RuneSlowClickApp {
    struct Settings: Sendable {
        var saves: UInt32 = 0
        var order: UInt64 = 0
    }

    private static let perfRecorder = PerfRecorder()

    @inline(never)
    static func sortSettings(_ seed: UInt64) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        let durationNs: UInt64 = 40_000_000
        var x = seed | 1
        while DispatchTime.now().uptimeNanoseconds &- start < durationNs {
            for _ in 0..<1000 {
                x = x &* 6364136223846793005 &+ 1
            }
        }
        return x
    }

    static func view(_ s: Settings, _ cx: inout Cx<Settings>) -> El<Settings> {
        let style = TextStyle(size: 14, weight: 400)
        var rows: El<Settings> = col().key("fields").gap(4)
        for i in 0..<40 {
            rows = rows.child(
                row()
                    .key("field-\(i)")
                    .h(20)
                    .child(text("Setting \(i)").font(style))
            )
        }

        let saveBtn: El<Settings> = el()
            .key("save")
            .size(80, 30)
            .rounded(6)
            .center()
            .bg(Color.white.alpha(0.12))
            .onClick { state in
                perfRecorder.measure("settings/toolbar/save", category: "ui.interaction") {
                    Thread.sleep(forTimeInterval: 0.04)
                    state.saves += 1
                }
            }
            .child(text("Save").font(style))

        let sortBtn: El<Settings> = el()
            .key("sort")
            .size(80, 30)
            .rounded(6)
            .center()
            .bg(Color.white.alpha(0.12))
            .onClick { state in
                perfRecorder.measure("settings/toolbar/sort", category: "ui.interaction") {
                    state.order = sortSettings(state.order)
                }
            }
            .child(text("Sort").font(style))

        return col()
            .key("settings")
            .wFull()
            .hFull()
            .p(16)
            .gap(12)
            .child(
                row()
                    .key("toolbar")
                    .gap(8)
                    .itemsCenter()
                    .child(saveBtn)
                    .child(sortBtn)
                    .child(text("saved \(s.saves)").font(style))
            )
            .child(rows)
    }

    static func makeApp() -> App<Settings> {
        App(title: "Slow click", size: Vec2(480, 360), state: Settings(), view: view)
    }

    static func main() throws {
        try makeApp().run()
    }
}
