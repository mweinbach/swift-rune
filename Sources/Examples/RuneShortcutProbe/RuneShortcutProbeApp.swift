import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/shortcut_probe.rs`.
@main
public enum RuneShortcutProbeApp {
    public struct State: Sendable {
        public var status: String = "Press registered shortcuts"
        public var triggers: Int = 0
        public init() {}
    }

    public struct Report: Sendable {
        public let registeredPrimary: Bool
        public let conflictRejected: Bool
        public let dispatchHandledId: String?
        public let triggerCount: Int
        public let unregisteredOK: Bool
        public let output: String
    }

    public static func runHeadlessVerify() -> Report {
        let registry = ShortcutRegistry()
        nonisolated(unsafe) var triggerCount = 0

        let first = registry.register(
            id: "probe.global",
            accelerator: "cmd+shift+k",
            scope: .global,
            label: "Probe Global"
        ) {
            triggerCount += 1
        }
        let conflict = registry.register(
            id: "probe.conflict",
            accelerator: "cmd+shift+k",
            scope: .global,
            label: "Probe Conflict"
        ) {}

        var conflictRejected = false
        if case .failure(.conflict(existingId: "probe.global")) = conflict {
            conflictRejected = true
        }

        let event = KeyEvent(key: .command("k"), mods: Mods(shift: true, cmd: true))
        let dispatched = registry.dispatch(event, activeScopes: [.global])
        var handledId: String? = nil
        if case .handled(let id) = dispatched {
            handledId = id
        }

        let unreg = registry.unregister(id: "probe.global")
        var unregisteredOK = false
        if case .success = unreg {
            unregisteredOK = true
        }

        let regOK: Bool
        if case .success = first { regOK = true } else { regOK = false }

        let out = "shortcut_probe registered=\(regOK) conflict=\(conflictRejected) handled=\(handledId ?? "none") count=\(triggerCount) unreg=\(unregisteredOK)"
        return Report(
            registeredPrimary: regOK,
            conflictRejected: conflictRejected,
            dispatchHandledId: handledId,
            triggerCount: triggerCount,
            unregisteredOK: unregisteredOK,
            output: out
        )
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--verify") || args.contains("--headless") {
            print(runHeadlessVerify().output)
            return
        }
        let report = runHeadlessVerify()
        let app = App(title: "shortcut_probe", state: State()) { s, _ in
            col()
                .wFull()
                .hFull()
                .p(20)
                .gap(8)
                .itemsCenter()
                .justifyCenter()
                .bg(Color.rgba8(0x0f, 0x11, 0x17))
                .child(text("Shortcut Probe").font(TextStyle(size: 16, weight: 600)).color(.white))
                .child(text(report.output).font(TextStyle(size: 12, weight: 400)).color(Color.white.alpha(0.75)))
        }
        .size(440, 200)
        try app.run()
    }
}
