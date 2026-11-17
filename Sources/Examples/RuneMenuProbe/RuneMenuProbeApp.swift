import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import AppKit
#endif

/// Native menu bar + dock menu + stdin control probe mirroring `crates/rune/examples/menu_probe.rs`.
@main
public enum RuneMenuProbeApp {
    private static let quickAccelerator = "mod+alt+shift+k"
    private static let namedQuickAccelerator = "mod+shift+p"
    private static let settingsAccelerator = "mod+shift+y"

    public struct State: Sendable {
        public var fired: UInt64 = 0
        public var status: String = "idle"
        public var checked: Bool = true
        public var disabled: Bool = false
        public init() {}
    }

    public struct Report: Sendable {
        public let itemCount: Int
        public let firstDispatchStatus: String
        public let countAfterDispatch: Int
        public let checkedAfterToggle: Bool
    }

    public static func menuItems(disabled: Bool = false, checked: Bool = true) -> [NativeMenuItem<State>] {
        makeMenuItems(disabled: disabled, checked: checked, replacement: false)
    }

    private static func makeMenuItems(disabled: Bool, checked: Bool, replacement: Bool) -> [NativeMenuItem<State>] {
        [
            NativeMenuItem<State>(
                id: "quick",
                title: replacement ? "Replacement Panel" : "Open Quick Panel",
                location: .app,
                keyEquivalent: replacement ? "mod+alt+shift+r" : quickAccelerator,
                enabled: !disabled
            ) { s, _ in
                s.fired &+= 1
                s.status = "triggered menu action #\(s.fired)"
                if replacement { RuneStandardIO.output("REPLACED quick\n") }
                RuneStandardIO.output("FIRED \(s.fired)\n")
            },
            NativeMenuItem<State>(
                id: "named_quick",
                title: "Named Quick Panel",
                location: .named("Rune Tools"),
                keyEquivalent: namedQuickAccelerator,
                keysFirst: true,
                enabled: !disabled
            ) { s, _ in
                s.fired &+= 1
                s.status = "triggered menu action #\(s.fired)"
                RuneStandardIO.output("FIRED \(s.fired)\n")
            },
            .separator(location: .named("Rune Tools")),
            NativeMenuItem<State>(
                id: "named_settings",
                title: "Named Settings",
                location: .named("Rune Tools"),
                keyEquivalent: settingsAccelerator,
                keysFirst: true,
                enabled: !disabled,
                checked: checked
            ) { s, _ in
                s.fired &+= 1
                s.checked.toggle()
                s.status = "triggered menu action #\(s.fired)"
                RuneStandardIO.output("FIRED \(s.fired)\n")
            },
            NativeMenuItem<State>(
                id: "dock_quick",
                title: "Dock Quick Panel",
                location: .dock,
                enabled: !disabled
            ) { s, _ in
                s.fired &+= 1
                s.status = "triggered menu action #\(s.fired)"
                RuneStandardIO.output("FIRED \(s.fired)\n")
            },
        ]
    }

    @MainActor
    public static func main() throws {
        QuitLifecycle.orderlyExit()

        var app = App<State>(
            "Menu Probe",
            size: Vec2(320, 120),
            init: { State() },
            view: { s, _ in
                col()
                    .wFull()
                    .hFull()
                    .bg(Color(r: 0.08, g: 0.09, b: 0.12, a: 1.0))
                    .center()
                    .gap(6)
                    .children([
                        text("Menu Probe")
                            .font(Tok.Typography.title)
                            .color(.white),
                        text("FIRED \(s.fired) · \(s.status)")
                            .font(Tok.Typography.label)
                            .color(Color(r: 0.75, g: 0.80, b: 0.88, a: 1.0)),
                    ])
            }
        )
        for item in menuItems() {
            app = app.menuItem(item)
        }
        let quick = try Chord.parse(quickAccelerator)
        let namedQuick = try Chord.parse(namedQuickAccelerator)
        let settings = try Chord.parse(settingsAccelerator)
        app = app.onKey { _, event, _ in
            if quick.matches(event) {
                RuneStandardIO.output("KEY handled quick\n")
                return true
            }
            if namedQuick.matches(event) {
                RuneStandardIO.output("KEY handled named_quick\n")
                return true
            }
            if settings.matches(event) {
                RuneStandardIO.output("KEY declined named_settings\n")
            }
            return false
        }
        app = app.onReady { _ in
            RuneStandardIO.output("READY\n")
        }

        let handle = app.handle()
        if !ToolingArgs.parse().isHeadlessRequested {
            Thread.detachNewThread {
                while let line = readLine() {
                    let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch cmd {
                    case "disable":
                        handle.update { s, _ in s.disabled = true }
                        do {
                            try handle.setMenu(menuItems(disabled: true))
                        } catch {
                            RuneStandardIO.output("ERR \(error)\n")
                        }
                    case "enable":
                        handle.update { s, _ in s.disabled = false }
                        do {
                            try handle.setMenu(menuItems(disabled: false))
                        } catch {
                            RuneStandardIO.output("ERR \(error)\n")
                        }
                    case "clear":
                        do {
                            try handle.setMenu([])
                        } catch {
                            RuneStandardIO.output("ERR \(error)\n")
                        }
                    case "replace":
                        do {
                            try handle.setMenu(makeMenuItems(disabled: false, checked: true, replacement: true))
                        } catch {
                            RuneStandardIO.output("ERR \(error)\n")
                        }
                    case "status":
                        let errors = handle.takeMenuErrors()
                        #if os(macOS)
                        let native = DispatchQueue.main.sync {
                            MainActor.assumeIsolated { nativeStatus() }
                        }
                        RuneStandardIO.output("STATUS \(native) errors=\(errors.count)\n")
                        #elseif os(Linux) || os(Windows)
                        let snapshot = AppMenuBridge.snapshot(for: handle.shared)
                        let items = snapshot.items.filter { !$0.isSeparator && $0.location != .dock }
                        let enabled = items.filter(\.enabled).count
                        RuneStandardIO.output(
                            "STATUS native_supported=\(AppMenuBridge.defaultNativeSupported) model_items=\(items.count)"
                                + " model_enabled=\(enabled) revision=\(snapshot.revision) errors=\(errors.count)\n"
                        )
                        #else
                        RuneStandardIO.output("STATUS unsupported errors=\(errors.count)\n")
                        #endif
                    case "quit":
                        handle.quit()
                        return
                    case "":
                        continue
                    default:
                        RuneStandardIO.output("UNKNOWN \(cmd)\n")
                    }
                }
                handle.quit()
            }
        }

        try app.run()
    }

    public static func runHeadlessVerify() throws -> Report {
        let items = menuItems(disabled: false, checked: true)
        let bar = NativeMenuBar<State>()
        try bar.setValidatedItems(items)
        var state = State()
        var tx = Tx()
        try bar.dispatch(id: "quick", state: &state, tx: &tx)
        let firstStatus = state.status
        state.fired = 10
        try bar.dispatch(id: "named_settings", state: &state, tx: &tx)
        return Report(
            itemCount: bar.items.count,
            firstDispatchStatus: firstStatus,
            countAfterDispatch: Int(state.fired),
            checkedAfterToggle: !state.checked
        )
    }

    #if os(macOS)
    @MainActor
    private static func nativeStatus() -> String {
        let mainMenu = NSApplication.shared.mainMenu
        let topCount = mainMenu?.items.count ?? 0
        let appSubCount = mainMenu?.items.first?.submenu?.items.count ?? 0
        let namedTitles = mainMenu?.items.dropFirst().map(\.title) ?? []
        let dockMenu = NSApplication.shared.delegate?.applicationDockMenu?(NSApplication.shared)
        let dockCount = dockMenu?.items.count ?? 0
        return "top=\(topCount) app_items=\(appSubCount) named=\(namedTitles) dock_items=\(dockCount)"
    }
    #endif
}
