import Foundation
import Rune

/// Global shortcut registration, conflict probing, runtime register/unregister, and dispatch probe
/// mirroring `crates/rune/examples/shortcut_probe.rs`.
@main
public enum RuneShortcutProbeApp {
    public struct State: Sendable {
        public var fired: UInt64 = 0
        public init() {}
    }

    public struct Report: Sendable {
        public let registeredPrimary: Bool
        public let conflictRejected: Bool
        public let dispatchHandledId: String?
        public let triggerCount: Int
        public let unregisteredOK: Bool
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: UInt64 = 0
        func increment() -> UInt64 {
            lock.withLock {
                count &+= 1
                return count
            }
        }
        func value() -> UInt64 { lock.withLock { count } }
    }

    private static let primaryAccel = "cmd+ctrl+alt+shift+k"
    private static let secondaryAccel = "ctrl+alt+shift+f11"

    @MainActor
    public static func main() throws {
        QuitLifecycle.orderlyExit()

        let rawArgs = Array(CommandLine.arguments.dropFirst())
        let probeConflict = rawArgs.contains("--probe-conflict")
        let forwardedArgs = rawArgs.filter { $0 != "--probe-conflict" }
        let firedCounter = AtomicCounter()
        let app = App<State>(
            "Shortcut Probe",
            size: Vec2(240, 100),
            init: { State() },
            view: { s, _ in
                col()
                    .sizeFull()
                    .bg(Color(r: 0.08, g: 0.09, b: 0.12, a: 1.0))
                    .center()
                    .child(text("FIRED \(s.fired)").font(Tok.Typography.title).color(.white))
            }
        )
        .globalShortcut(primaryAccel) { state in
            state.fired = firedCounter.increment()
            RuneStandardIO.output("FIRED \(state.fired)\n")
        }
        .args(forwardedArgs)
        .windowless(true)
        .accessory(true)

        let handle = app.handle()
        if !ToolingArgs.parse(forwardedArgs).isHeadlessRequested {
            handle.update { _, tx in
                let errors = handle.takeShortcutErrors()
                if probeConflict, errors.count == 1, case .alreadyInUse = errors[0] {
                    RuneStandardIO.output("CONFLICT\n")
                    tx.quit()
                    return
                }
                guard errors.isEmpty, !probeConflict else {
                    RuneStandardIO.error("Shortcut probe received unexpected registration results: \(errors)\n")
                    tx.quit()
                    return
                }
                do {
                    let key = try ParsedShortcut.parseOn(secondaryAccel)
                    let id = try handle.registerShortcut(key) { _, _ in }.get()
                    try handle.unregisterShortcut(id).get()
                    RuneStandardIO.output("READY\n")
                } catch {
                    RuneStandardIO.error("Shortcut probe could not register and unregister: \(error)\n")
                    tx.quit()
                }
            }
            if !probeConflict {
                Thread.detachNewThread {
                    while readLine() != nil {}
                    handle.quit()
                }
            }
        }
        try app.run(arguments: forwardedArgs)
    }

    public static func runHeadlessVerify() -> Report {
        let registry = ShortcutRegistry()
        let hits = AtomicCounter()
        let reg1 = registry.register(id: "probe.global", accelerator: primaryAccel, scope: .global) {
            _ = hits.increment()
        }
        let reg2 = registry.register(id: "probe.conflict", accelerator: primaryAccel, scope: .global) {}

        let registeredPrimary: Bool = {
            if case .success = reg1 { return true }
            return false
        }()
        let conflictRejected: Bool = {
            if case .failure(.conflict) = reg2 { return true }
            return false
        }()

        let event = KeyEvent(
            key: .text("k"),
            mods: Mods(shift: true, ctrl: true, alt: true, cmd: true)
        )
        let dispatched = registry.dispatch(event, activeScopes: [.global])
        let handledId: String? = {
            if case .handled(let id) = dispatched { return id }
            return nil
        }()
        let unreg = registry.unregister(id: "probe.global")
        let unregisteredOK: Bool = {
            if case .success = unreg { return true }
            return false
        }()

        return Report(
            registeredPrimary: registeredPrimary,
            conflictRejected: conflictRejected,
            dispatchHandledId: handledId,
            triggerCount: Int(hits.value()),
            unregisteredOK: unregisteredOK
        )
    }
}
