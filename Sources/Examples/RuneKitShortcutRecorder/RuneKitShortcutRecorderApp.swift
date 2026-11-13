import Foundation
import Rune
import RuneKit

/// Port of `crates/rune-kit/examples/shortcut_recorder.rs`.
/// Ctrl-Shift-Space is reserved locally as a conflict demonstration until `App.globalShortcut`
/// lands from `gap/platform`.
public struct ShortcutRecorderDemoState: Sendable {
    public var recorder = ShortcutRecorderState()
    public var registered: ShortcutChord? = nil
    public var activations: Int = 0
    public var owner: String? = nil

    public init() {}
}

public enum RuneKitShortcutRecorderApp {
    public static let reservedConflict = ShortcutChord(key: "space", modifiers: [.control, .shift])

    public static func change(state: inout ShortcutRecorderDemoState, next: ShortcutChord?) -> ShortcutValidationError? {
        if let next, next == reservedConflict {
            state.owner = "Rune shortcut demo"
            return .conflict
        }
        state.owner = nil
        state.registered = next
        return nil
    }

    public static func mapModifiers(_ mods: Mods) -> ShortcutModifiers {
        var out: ShortcutModifiers = []
        if mods.cmd { out.insert(.command) }
        if mods.ctrl { out.insert(.control) }
        if mods.alt { out.insert(.option) }
        if mods.shift { out.insert(.shift) }
        return out
    }

    public static func mapKey(_ key: Key) -> String? {
        switch key {
        case .text(let s): return s
        case .command(let c): return String(c)
        case .enter: return "Return"
        case .escape: return "Escape"
        case .backspace: return "Backspace"
        case .delete: return "Delete"
        case .tab: return "Tab"
        case .space: return "space"
        case .arrowLeft: return "Left"
        case .arrowRight: return "Right"
        case .arrowUp: return "Up"
        case .arrowDown: return "Down"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PageUp"
        case .pageDown: return "PageDown"
        case .f(let n): return "F\(n)"
        case .insert: return "Insert"
        case .contextMenu: return "Menu"
        case .printScreen: return "PrintScreen"
        case .scrollLock: return "ScrollLock"
        case .pause: return "Pause"
        case .modifier: return nil
        }
    }

    public static func view(state: ShortcutRecorderDemoState, cx: inout Cx<ShortcutRecorderDemoState>) -> El<ShortcutRecorderDemoState> {
        let k = Kit.neutral(dark: true)
        var root: El<ShortcutRecorderDemoState> = col()
            .p(24)
            .gap(16)
            .wFull()
            .hFull()
            .bg(k.c.page)
            .child(text("Launcher shortcut").font(k.ty.uiCompact).color(k.c.textBase))
            .child(
                k.shortcutRecorder(
                    key: "shortcut",
                    state: state.recorder,
                    onBegin: { s in s.recorder.begin() },
                    onClear: { s in
                        _ = change(state: &s, next: nil)
                        s.recorder.shortcut = nil
                        s.recorder.cancel()
                    }
                )
            )
            .child(text("Activations: \(state.activations)").font(k.ty.uiCompact).color(k.c.textMuted))

        if let owner = state.owner, let chord = state.recorder.refusedChord {
            root = root.child(
                text("\(chord.keycaps.joined(separator: " ")) is used by \(owner).")
                    .font(k.ty.smallMedium)
                    .color(k.c.danger.fg)
            )
        }
        return root
    }

    public static func onKey(state: inout ShortcutRecorderDemoState, event: KeyEvent, tx: inout Tx) -> Bool {
        if state.recorder.isRecording {
            if let keyName = mapKey(event.key) {
                let mods = mapModifiers(event.mods)
                var copyState = state
                var rec = copyState.recorder
                let handled = rec.handle(.keyDown(key: keyName, modifiers: mods, isRepeat: false)) { chord in
                    change(state: &copyState, next: chord)
                }
                copyState.recorder = rec
                state = copyState
                return handled
            }
            return false
        }
        if let active = state.registered,
           let keyName = mapKey(event.key),
           keyName.lowercased() == active.key.lowercased(),
           mapModifiers(event.mods) == active.modifiers {
            state.activations += 1
            return true
        }
        return false
    }

    public static func makeApp() -> App<ShortcutRecorderDemoState> {
        App(title: "Shortcut recorder", size: Vec2(360, 180), state: ShortcutRecorderDemoState(), view: view)
            .onKey(onKey)
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
