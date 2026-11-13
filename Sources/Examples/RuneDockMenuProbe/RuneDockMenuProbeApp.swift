import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/dock_menu_probe.rs`.
@main
public enum RuneDockMenuProbeApp {
    public struct State: Sendable {
        public var status: String = "starting as accessory"
        public var dockClicks: Int = 0
        public var promoted: Bool = false
        public init() {}
    }

    public struct Report: Sendable {
        public let isAccessory: Bool
        public let dockMenuItemCount: Int
        public let dockClicksAfterDispatch: Int
        public let validIcon: Bool
        public let output: String
    }

    public static func dockItems() -> [NativeMenuItem<State>] {
        [
            NativeMenuItem(id: "dock.new_item", title: "New Probe Event", location: .dock) { s, _ in
                s.dockClicks += 1
                s.status = "dock event #\(s.dockClicks)"
            },
            NativeMenuItem(id: "dock.promote", title: "Promote to Regular", location: .dock) { s, _ in
                s.promoted = true
                s.status = "promoted"
            },
        ]
    }

    public static func makeProbeIcon() -> AppIcon? {
        let w = 16
        let h = 16
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = 90
            rgba[i + 1] = 175
            rgba[i + 2] = 250
            rgba[i + 3] = 255
        }
        return AppIcon(width: w, height: h, rgba: Data(rgba))
    }

    public static func makeApp() -> App<State> {
        var app = App(title: "dock_menu_probe", state: State()) { s, _ in
            col()
                .wFull()
                .hFull()
                .p(20)
                .gap(8)
                .itemsCenter()
                .justifyCenter()
                .bg(Color.rgba8(0x0d, 0x10, 0x16))
                .child(text("Dock Menu Probe").font(TextStyle(size: 16, weight: 600)).color(.white))
                .child(text(s.status).font(TextStyle(size: 13, weight: 400)).color(Color.white.alpha(0.75)))
        }
        .size(400, 200)
        .accessory(true)
        for item in dockItems() {
            app = app.menuItem(item)
        }
        return app
    }

    public static func runHeadlessVerify() throws -> Report {
        let app = makeApp()
        let bar = NativeMenuBar<State>()
        try bar.setValidatedItems(dockItems())
        var state = State()
        var tx = Tx()
        try bar.dispatch(id: "dock.new_item", state: &state, tx: &tx)
        try bar.dispatch(id: "dock.promote", state: &state, tx: &tx)
        let icon = makeProbeIcon()

        let out = "dock_menu_probe accessory=\(app.isAccessory) items=\(bar.items.count) clicks=\(state.dockClicks) iconValid=\(icon != nil)"
        return Report(
            isAccessory: app.isAccessory,
            dockMenuItemCount: bar.items.count,
            dockClicksAfterDispatch: state.dockClicks,
            validIcon: icon != nil,
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
        let app = makeApp()
        if let icon = makeProbeIcon() {
            app.handle().setDockIcon(icon)
        }
        try app.run()
    }
}
