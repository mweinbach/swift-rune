import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif

/// Global shortcut registration, conflict probing, runtime register/unregister, and dispatch probe
/// mirroring `crates/rune/examples/shortcut_probe.rs`.
///
/// NOTE: `Sources/Rune` does not yet expose `App.globalShortcut(...)` or
/// `AppHandle.{takeShortcutErrors,registerShortcut,unregisterShortcut}`. This port drives
/// `ShortcutRegistry` and `MacOSGlobalHotKeyBackend` directly under a windowless `.accessory()`
/// `App` while honoring `--probe-conflict`, `--tree`, `READY`, `CONFLICT`, `FIRED`, and stdin EOF.
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
        let isHeadless = ToolingArgs.parse(forwardedArgs).isHeadlessRequested

        let firedCounter = AtomicCounter()
        let registry = ShortcutRegistry()

        #if os(macOS)
        let backend = isHeadless ? nil : (try? MacOSGlobalHotKeyBackend())
        #endif

        let app = App<State>(
            "Shortcut Probe",
            size: Vec2(240, 100),
            init: { State() },
            view: { s, _ in
                col()
                    .wFull()
                    .hFull()
                    .bg(Color(r: 0.08, g: 0.09, b: 0.12, a: 1.0))
                    .center()
                    .child(
                        text("FIRED \(s.fired)")
                            .font(Tok.Typography.title)
                            .color(.white)
                    )
            }
        )
        .args(forwardedArgs)
        .windowless(true)
        .accessory(true)

        let handle = app.handle()

        if !isHeadless {
            let primaryRes = registry.register(id: "primary", accelerator: primaryAccel, scope: .global) {
                let n = firedCounter.increment()
                handle.update { s, _ in s.fired = n }
                print("FIRED \(n)")
                fflush(stdout)
            }
            #if os(macOS)
            if case .success = primaryRes, let chord = Chord(parsing: primaryAccel), let backend {
                let osRes = backend.register(id: "primary", chord: chord) {
                    let n = firedCounter.increment()
                    handle.update { s, _ in s.fired = n }
                    print("FIRED \(n)")
                    fflush(stdout)
                }
                if case .failure = osRes, probeConflict {
                    print("CONFLICT")
                    fflush(stdout)
                    return
                }
            }
            #endif

            if probeConflict {
                let dupRes = registry.register(id: "conflict", accelerator: primaryAccel, scope: .global) {}
                if case .failure(.conflict) = dupRes {
                    print("CONFLICT")
                    fflush(stdout)
                    return
                }
            }

            let extraRes = registry.register(id: "extra", accelerator: secondaryAccel, scope: .global) {
                let n = firedCounter.increment()
                handle.update { s, _ in s.fired = n }
                print("FIRED \(n)")
                fflush(stdout)
            }
            #if os(macOS)
            if case .success = extraRes, let chord = Chord(parsing: secondaryAccel) {
                _ = backend?.register(id: "extra", chord: chord) {
                    let n = firedCounter.increment()
                    handle.update { s, _ in s.fired = n }
                    print("FIRED \(n)")
                    fflush(stdout)
                }
            }
            #endif

            _ = registry.unregister(id: "extra")
            #if os(macOS)
            _ = backend?.unregister(id: "extra")
            #endif

            print("READY")
            fflush(stdout)

            Thread.detachNewThread {
                while readLine() != nil {}
                handle.quit()
            }
        }

        try app.run(arguments: forwardedArgs)
        if !isHeadless {
            print("FIRED \(firedCounter.value())")
            fflush(stdout)
        }
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
