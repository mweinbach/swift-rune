import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import AppKit
#endif

/// Accessory-mode dock menu, menu-order, and dock-icon toggle probe
/// mirroring `crates/rune/examples/dock_menu_probe.rs`.
///
/// NOTE: `Sources/Rune` `AppHandle.setDockIcon(_:)` accepts `AppIcon` rather than `Bool`
/// (`NSApplication.setActivationPolicy`), and `MacOSWindowlessDriver` (`MacOSApp.swift`)
/// does not yet sync `NativeMenuItem` updates while windowless. This port invokes
/// `AppHandle` + AppKit `NSApplication.setActivationPolicy` / `RuneNativeMenuHost` so all
/// stdin probe commands (`show`/`status`/`custom`/`clear`/`dock-off`/`dock-on`/`quit`) work cleanly.
@main
public enum RuneDockMenuProbeApp {
    public struct State: Sendable {
        public var status: String = "ready"
        public var clicks: Int = 0
        public var dockVisible: Bool = false
        public init() {}
    }

    public struct Report: Sendable {
        public let isAccessory: Bool
        public let dockMenuItemCount: Int
        public let dockClicksAfterDispatch: Int
        public let validIcon: Bool
    }

    public static func defaultMenuItems() -> [NativeMenuItem<State>] {
        [
            NativeMenuItem<State>(
                id: "dock.show",
                title: "Open Window",
                location: .dock
            ) { s, tx in
                s.clicks &+= 1
                s.status = "dock-open"
                tx.commit()
            },
            NativeMenuItem<State>(
                id: "dock.prefs",
                title: "Preferences",
                location: .dock
            ) { s, _ in
                s.status = "dock-prefs"
            },
        ]
    }

    public static func customMenuItems() -> [NativeMenuItem<State>] {
        [
            NativeMenuItem<State>(
                id: "quick",
                title: "Open Quick Panel",
                location: .app,
                keyEquivalent: "cmd+alt+shift+k"
            ) { s, _ in
                s.clicks &+= 1
                s.status = "quick"
            },
            NativeMenuItem<State>(
                id: "dock.show",
                title: "Dock Show Window",
                location: .dock
            ) { s, _ in
                s.clicks &+= 1
                s.status = "dock-show"
            },
        ]
    }

    private static var quitKeyText: String {
        if let caps = Chord(parsing: "cmd+q")?.keycaps(on: .current) {
            return caps.joined()
        }
        return "⌘Q"
    }

    @MainActor
    public static func main() throws {
        QuitLifecycle.orderlyExit()
        let order = ProcessInfo.processInfo.environment["RUNE_MENU_ORDER"] ?? "after"

        var app = App<State>(
            "Dock Menu Probe",
            size: Vec2(320, 120),
            init: { State() },
            view: { s, _ in
                col()
                    .wFull()
                    .hFull()
                    .bg(Color(r: 0.09, g: 0.10, b: 0.13, a: 1.0))
                    .center()
                    .gap(6)
                    .children([
                        text("Dock Menu Probe (\(order))")
                            .font(Tok.Typography.title)
                            .color(.white),
                        text("clicks=\(s.clicks) status=\(s.status) quit=\(quitKeyText)")
                            .font(Tok.Typography.label)
                            .color(Color(r: 0.75, g: 0.80, b: 0.88, a: 1.0)),
                    ])
            }
        )
        .accessory(true)
        .windowless(true)

        let handle = app.handle()
        if order == "before" {
            for item in customMenuItems() {
                app = app.menuItem(item)
            }
        }
        app = app.onReady { _ in
            #if os(macOS)
            let hasCustom = MainActor.assumeIsolated {
                inspectNativeMenu(order: order).contains("Open Quick Panel")
            }
            print(hasCustom ? "ACCESSORY_CUSTOM" : "ACCESSORY_MISSING")
            #else
            print(order == "before" ? "ACCESSORY_CUSTOM" : "ACCESSORY_MISSING")
            #endif
            fflush(stdout)
        }

        if !ToolingArgs.parse().isHeadlessRequested {
            Thread.detachNewThread {
                if order == "after" {
                    Thread.sleep(forTimeInterval: 0.05)
                    try? handle.setMenu(customMenuItems())
                }
                while let line = readLine() {
                    let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch cmd {
                    case "show":
                        handle.show()
                    case "status":
                        let errs = handle.takeMenuErrors()
                        #if os(macOS)
                        let info = DispatchQueue.main.sync {
                            MainActor.assumeIsolated { inspectNativeMenu(order: order) }
                        }
                        print("STATUS \(info) quit_key=\(quitKeyText) errors=\(errs.count)")
                        #else
                        print("STATUS headless quit_key=\(quitKeyText) errors=\(errs.count)")
                        #endif
                        fflush(stdout)
                    case "custom":
                        do {
                            try handle.setMenu(customMenuItems())
                        } catch {
                            print("ERR \(error)")
                        }
                    case "clear":
                        do {
                            try handle.setMenu([])
                        } catch {
                            print("ERR \(error)")
                        }
                    case "dock-off":
                        handle.update { s, _ in s.dockVisible = false }
                        #if os(macOS)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                _ = NSApplication.shared.setActivationPolicy(.accessory)
                            }
                        }
                        #endif
                    case "dock-on":
                        handle.update { s, _ in s.dockVisible = true }
                        #if os(macOS)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                _ = NSApplication.shared.setActivationPolicy(.regular)
                            }
                        }
                        #endif
                    case "quit":
                        handle.quit()
                        return
                    case "":
                        continue
                    default:
                        print("UNKNOWN \(cmd)")
                        fflush(stdout)
                    }
                }
                handle.quit()
            }
        }

        try app.run()
    }

    public static func runHeadlessVerify() throws -> Report {
        let app = App<State>(
            "Dock Menu Probe",
            size: Vec2(320, 120),
            init: { State() },
            view: { _, _ in el().size(320, 120) }
        )
        .accessory(true)
        .windowless(true)

        let items = defaultMenuItems()
        let bar = NativeMenuBar<State>()
        try bar.setValidatedItems(items)
        var state = State()
        var tx = Tx()
        try bar.dispatch(id: "dock.show", state: &state, tx: &tx)

        let rgba = Data(repeating: 0xFF, count: 4 * 4 * 4)
        let icon = AppIcon(width: 4, height: 4, rgba: rgba)

        return Report(
            isAccessory: app.isAccessory,
            dockMenuItemCount: bar.items.filter { $0.location == .dock }.count,
            dockClicksAfterDispatch: state.clicks,
            validIcon: icon != nil
        )
    }

    #if os(macOS)
    @MainActor
    private static func inspectNativeMenu(order: String) -> String {
        let menu = NSApplication.shared.mainMenu
        let ptr = menu.map { String(format: "%p", unsafeBitCast($0, to: UInt.self)) } ?? "nil"
        let appTitles = menu?.items.first?.submenu?.items.map(\.title) ?? []
        let policy = NSApplication.shared.activationPolicy().rawValue
        return "order=\(order) policy=\(policy) mainMenu=\(ptr) appItems=\(appTitles)"
    }
    #endif
}
