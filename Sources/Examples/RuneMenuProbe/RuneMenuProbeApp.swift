import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/menu_probe.rs`.
@main
public enum RuneMenuProbeApp {
    public struct State: Sendable {
        public var status: String = "idle"
        public var count: Int = 0
        public var checked: Bool = false
        public init() {}
    }

    public struct Report: Sendable {
        public let itemCount: Int
        public let firstDispatchStatus: String
        public let countAfterDispatch: Int
        public let checkedAfterToggle: Bool
        public let output: String
    }

    public static func menuItems() -> [NativeMenuItem<State>] {
        [
            NativeMenuItem(id: "app.about.probe", title: "Menu Probe Action", location: .app, keyEquivalent: "mod+m") { s, _ in
                s.count += 1
                s.status = "triggered menu action #\(s.count)"
            },
            NativeMenuItem(id: "view.toggle", title: "Toggle Checkmark", location: .named("View"), keyEquivalent: "mod+t", checked: true) { s, _ in
                s.checked.toggle()
                s.status = s.checked ? "checked" : "unchecked"
            },
            .separator(location: .named("View")),
            NativeMenuItem(id: "view.reset", title: "Reset Counter", location: .named("View")) { s, _ in
                s.count = 0
                s.status = "reset"
            },
            NativeMenuItem(id: "dock.ping", title: "Dock Ping", location: .dock) { s, _ in
                s.count += 10
                s.status = "dock-ping"
            },
        ]
    }

    public static func makeApp() -> App<State> {
        var app = App(title: "menu_probe", state: State()) { s, _ in
            col()
                .wFull()
                .hFull()
                .p(20)
                .gap(8)
                .itemsCenter()
                .justifyCenter()
                .bg(Color.rgba8(0x0e, 0x10, 0x15))
                .child(text("Menu Probe").font(TextStyle(size: 16, weight: 600)).color(.white))
                .child(text("status: \(s.status) | count: \(s.count)").font(TextStyle(size: 13, weight: 400)).color(Color.white.alpha(0.75)))
        }
        .size(420, 220)
        for item in menuItems() {
            app = app.menuItem(item)
        }
        return app
    }

    public static func runHeadlessVerify() throws -> Report {
        let bar = NativeMenuBar<State>()
        let items = menuItems()
        try bar.setValidatedItems(items)

        var state = State()
        var tx = Tx()
        try bar.dispatch(id: "app.about.probe", state: &state, tx: &tx)
        let firstStatus = state.status
        try bar.dispatch(id: "view.toggle", state: &state, tx: &tx)
        let checked = state.checked
        try bar.dispatch(id: "dock.ping", state: &state, tx: &tx)

        let out = "menu_probe items=\(bar.items.count) first=\"\(firstStatus)\" count=\(state.count) checked=\(checked)"
        return Report(
            itemCount: bar.items.count,
            firstDispatchStatus: firstStatus,
            countAfterDispatch: state.count,
            checkedAfterToggle: checked,
            output: out
        )
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--verify") || args.contains("--headless") {
            print(try runHeadlessVerify().output)
            return
        }
        try makeApp().run()
    }
}
