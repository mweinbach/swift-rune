import Foundation

/// Tracks an app-managed IME composition when `App.onIme` handles preedit for a custom
/// `El.imeCursor()` surface (`crates/rune/src/runtime/input/app_ime.rs`).
public struct AppImeState: Sendable {
    public enum Composition: Equatable, Sendable {
        case idle
        case composing(String)
    }

    public private(set) var composition: Composition = .idle

    public init() {}

    public var isComposing: Bool {
        if case .composing = composition { return true }
        return false
    }

    public mutating func step(_ ime: Ime) {
        switch ime {
        case .preedit(let pre):
            composition = pre.text.isEmpty ? .idle : .composing(pre.text)
        case .commit:
            composition = .idle
        case .enabled, .disabled, .cancel, .deleteSurrounding:
            break
        }
    }

    public mutating func takeComposingText() -> String? {
        guard case .composing(let text) = composition else { return nil }
        composition = .idle
        return text
    }
}

extension Runtime {
    /// Steps `AppImeState` and invokes `onIme` when the app handles IME (no focused `textInput`,
    /// an active app composition still ending, or lifecycle `.enabled`/`.disabled`).
    internal func dispatchAppIme(_ ime: Ime, at now: Double) -> Bool {
        guard let hook = onIme else { return false }
        inputMachines.appIme.step(ime)
        var tx = makeTx(at: now)
        let handled = Tx.took(hook(&state, ime, &tx), &tx)
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: handled)
        return handled
    }

    /// Commits any open `AppImeState` composition via `onIme(.commit(...))`.
    internal func finishAppImeComposition(at now: Double) -> Bool {
        guard let text = inputMachines.appIme.takeComposingText() else { return false }
        return dispatchAppIme(.commit(text), at: now)
    }

    /// Dispatches a shell/test `Ime` event through the focused text field or app `onIme` (`Runtime::ime`).
    @discardableResult
    public func ime(_ event: Ime, at now: Double? = nil) -> Bool {
        let t = now ?? currentTime
        let activeIme: Bool = {
            if isAnyImeComposing { return true }
            switch event {
            case .preedit(let pre): return !pre.text.isEmpty
            case .commit(let s): return !s.isEmpty
            case .enabled, .disabled, .cancel, .deleteSurrounding: return false
            }
        }()
        let appOnly: Bool = {
            if inputMachines.appIme.isComposing { return true }
            switch event {
            case .enabled, .disabled: return true
            default: return !hasFocusedTextInput
            }
        }()
        if appOnly {
            let ran = dispatchAppIme(event, at: t)
            if ran && activeIme { inputMachines.keyReleases.imeTookKey() }
            return ran
        }
        let ran: Bool
        switch event {
        case .preedit(let pre):
            ran = applyImeToFocusedField(.preedit(pre.text, cursorUTF8: pre.cursorUTF8, clauses: pre.clauses), at: t)
        case .commit(let s):
            ran = applyImeToFocusedField(.commit(s), at: t)
        case .cancel:
            ran = applyImeToFocusedField(.preedit("", cursorUTF8: nil, clauses: []), at: t)
        case .deleteSurrounding:
            ran = false
        case .enabled, .disabled:
            ran = false
        }
        if ran && activeIme { inputMachines.keyReleases.imeTookKey() }
        return ran
    }
}
