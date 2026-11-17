import Foundation
import Rune
import RuneKit

/// Port of `crates/rune-kit/examples/shortcut_recorder.rs`.
public struct ShortcutRecorderDemoState: Sendable {
    public var recorder = ShortcutRecorderState()
    public var registered: ShortcutChord?
    public var activations = 0
    public var owner: String?
    var handle: AppHandle<ShortcutRecorderDemoState>?
    var registration: UInt32?

    public init() {}
}

public enum RuneKitShortcutRecorderApp {
    public static let reservedConflict = ShortcutChord(key: "space", modifiers: [.control, .shift])

    private static func validationError(_ error: ShortcutError) -> ShortcutValidationError {
        switch error {
        case .alreadyInUse, .conflict: .conflict
        case .invalidAccelerator: .invalidKey
        case .unmodifiedDisallowed: .missingModifier
        case .permissionDenied: .permissionDenied
        case .unsupported: .unsupported
        case .rejectedByOS(let message): .custom(message)
        case .notRunning: .custom("The shortcut service is not running.")
        case .unknownId: .custom("The previous shortcut is no longer registered.")
        }
    }

    public static func change(state: inout ShortcutRecorderDemoState, next: ShortcutChord?) -> ShortcutValidationError? {
        state.owner = nil
        guard let handle = state.handle else { return validationError(.notRunning) }
        var newID: UInt32?
        if let next {
            let shortcut: ParsedShortcut
            do {
                shortcut = try next.parsedShortcut()
            } catch {
                return validationError(error)
            }
            switch handle.registerShortcut(shortcut, { state, _ in state.activations += 1 }) {
            case .success(let id):
                newID = id
            case .failure(let error):
                if case .alreadyInUse(let owner) = error {
                    state.owner = owner ?? handle.shortcutOwner(shortcut)
                } else if case .conflict = error {
                    state.owner = handle.shortcutOwner(shortcut)
                }
                return validationError(error)
            }
        }
        if let oldID = state.registration, case .failure(let error) = handle.unregisterShortcut(oldID) {
            if let newID, case .failure(let rollbackError) = handle.unregisterShortcut(newID) {
                return validationError(rollbackError)
            }
            return validationError(error)
        }
        state.registration = newID
        state.registered = next
        return nil
    }

    public static func view(state: ShortcutRecorderDemoState, cx: inout Cx<ShortcutRecorderDemoState>) -> El<ShortcutRecorderDemoState> {
        let k = Kit.neutral(dark: true)
        return col()
            .p(24)
            .gap(16)
            .wFull()
            .hFull()
            .bg(k.c.page)
            .child(text("Launcher shortcut").font(k.ty.uiCompact).color(k.c.textBase))
            .child(
                ShortcutRecorder<ShortcutRecorderDemoState>(key: "shortcut", \.recorder)
                    .onChange(change)
                    .errorMessage { error, chord in
                        if let chord, let owner = state.owner {
                            return "\(chord.keycaps.joined(separator: " ")) is used by \(owner)."
                        }
                        return error.defaultMessage(for: chord)
                    }
                    .build(using: k, in: state)
            )
            .child(text("Activations: \(state.activations)").font(k.ty.uiCompact).color(k.c.textMuted))
    }

    public static func makeApp() -> App<ShortcutRecorderDemoState> {
        let app = App(title: "Shortcut recorder", size: Vec2(360, 180), state: ShortcutRecorderDemoState(), view: view)
            .globalShortcut("ctrl+shift+space") { _ in }
        let handle = app.handle()
        return app.initState {
            var state = ShortcutRecorderDemoState()
            state.handle = handle
            return state
        }
    }
}

@main
enum RuneKitShortcutRecorderMain {
    static func main() throws {
        if CommandLine.arguments.contains("--labels") {
            let samples = [
                ShortcutChord(key: "q", modifiers: [.command]),
                ShortcutChord(key: "/", modifiers: [.control]),
                ShortcutChord(key: "space", modifiers: [.shift]),
            ]
            for s in samples {
                print("\(s.displayString) \(s.key) \(s.keycaps)")
            }
            return
        }
        try RuneKitShortcutRecorderApp.makeApp().run()
    }
}
