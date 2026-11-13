import Foundation
import Rune

/// Keyboard modifiers captured by `ShortcutRecorderState`.
public struct ShortcutModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option  = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift   = ShortcutModifiers(rawValue: 1 << 3)

    public var keycaps: [String] {
        keycaps(macOS: true)
    }

    public func keycaps(macOS: Bool) -> [String] {
        var caps: [String] = []
        if macOS {
            if contains(.control) { caps.append("⌃") }
            if contains(.option)  { caps.append("⌥") }
            if contains(.shift)   { caps.append("⇧") }
            if contains(.command) { caps.append("⌘") }
        } else {
            if contains(.control) { caps.append("Ctrl") }
            if contains(.option)  { caps.append("Alt") }
            if contains(.shift)   { caps.append("Shift") }
            if contains(.command) { caps.append("Super") }
        }
        return caps
    }
}

/// A recorded physical key chord (`rune::Shortcut`).
public struct ShortcutChord: Sendable, Equatable, Hashable {
    public var key: String
    public var modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public var keycaps: [String] {
        keycaps(macOS: true)
    }

    public func keycaps(macOS: Bool) -> [String] {
        modifiers.keycaps(macOS: macOS) + [key.uppercased()]
    }

    public var displayString: String {
        displayString(macOS: true)
    }

    public func displayString(macOS: Bool) -> String {
        let caps = keycaps(macOS: macOS)
        return macOS ? caps.joined() : caps.joined(separator: "+")
    }

    public var hasPrimaryModifier: Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    public func requireModifier() -> Result<Void, ShortcutValidationError> {
        let upper = key.uppercased()
        let isFunctionKey = upper.hasPrefix("F") && Int(upper.dropFirst()).map { (1...24).contains($0) } == true
        if hasPrimaryModifier || isFunctionKey {
            return .success(())
        }
        return .failure(.missingModifier)
    }
}

/// Validation / registration error for `ShortcutRecorder` (`rune::ShortcutError`).
public enum ShortcutValidationError: Error, Sendable, Equatable {
    case missingModifier
    case invalidKey
    case conflict
    case unsupported
    case permissionDenied
    case custom(String)

    public func defaultMessage(for chord: ShortcutChord?) -> String {
        defaultMessage(for: chord, macOS: true)
    }

    public func defaultMessage(for chord: ShortcutChord?, macOS: Bool) -> String {
        guard let chord else {
            return self == .invalidKey ? "That key can't be part of a shortcut." : "The shortcut couldn't be cleared."
        }
        let label = chord.displayString(macOS: macOS)
        switch self {
        case .missingModifier:
            return macOS ? "Add ⌘, ⌃ or ⌥." : "Add Ctrl, Alt or Super."
        case .invalidKey: return "That key can't be part of a shortcut."
        case .conflict: return "\(label) is already in use."
        case .unsupported: return "This desktop doesn't support global shortcuts."
        case .permissionDenied: return "Permission to use \(label) was declined."
        case .custom(let msg): return msg
        }
    }
}

/// Input event fed to `ShortcutRecorderState`.
public enum ShortcutInputEvent: Sendable, Equatable {
    case focusLost
    case modifiersChanged(ShortcutModifiers)
    case keyDown(key: String, modifiers: ShortcutModifiers, isRepeat: Bool)
    case keyUp(String)
}

/// State machine for `ShortcutRecorder` (`rune_kit::shortcut_recorder::ShortcutRecorderState`).
public struct ShortcutRecorderState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case capturing(error: ShortcutValidationError?, refused: ShortcutChord?, finishing: String?)
        case swallowing(key: String)

        public var finishingKey: String? {
            switch self {
            case .capturing(_, _, let key): return key
            case .swallowing(let key): return key
            case .idle: return nil
            }
        }
    }

    public var shortcut: ShortcutChord?
    public var phase: Phase
    public var heldModifiers: ShortcutModifiers
    public var unregistered: Bool

    public init(shortcut: ShortcutChord? = nil) {
        self.shortcut = shortcut
        self.phase = .idle
        self.heldModifiers = []
        self.unregistered = false
    }

    public static func isModifierKey(_ key: String) -> Bool {
        switch key.lowercased() {
        case "shift", "shiftleft", "shiftright",
             "control", "controlleft", "controlright", "ctrl",
             "alt", "altleft", "altright", "option", "optionleft", "optionright",
             "super", "superleft", "superright", "command", "cmd", "meta", "logo",
             "fn", "fnlock":
            return true
        default:
            return false
        }
    }

    public var isRecording: Bool {
        if case .capturing = phase { return true }
        return false
    }

    public var isSwallowing: Bool {
        if case .swallowing = phase { return true }
        return false
    }

    public var error: ShortcutValidationError? {
        if case .capturing(let err, _, _) = phase { return err }
        return nil
    }

    public var refusedChord: ShortcutChord? {
        if case .capturing(_, let chord, _) = phase { return chord }
        return nil
    }

    public var keycaps: [String] {
        keycaps(macOS: true)
    }

    public func keycaps(macOS: Bool) -> [String] {
        if let refused = refusedChord {
            return refused.keycaps(macOS: macOS)
        }
        if isRecording {
            return heldModifiers.keycaps(macOS: macOS)
        }
        return shortcut?.keycaps(macOS: macOS) ?? []
    }

    public mutating func markUnregistered() {
        unregistered = true
    }

    public mutating func begin() {
        phase = .capturing(error: nil, refused: nil, finishing: nil)
    }

    /// Ends the capture, keeping any finishing key so its repeats and release remain swallowed.
    public mutating func cancel() {
        if let finishing = phase.finishingKey {
            phase = .swallowing(key: finishing)
        } else {
            phase = .idle
        }
        heldModifiers = []
    }

    /// Clears the stored shortcut directly when triggered via reset/clear button.
    @discardableResult
    public mutating func clear(onChange: ((ShortcutChord?) -> ShortcutValidationError?)? = nil) -> Bool {
        clearWithValidator { chord in onChange?(chord) }
    }

    /// Non-escaping validator variant for synchronous `inout State` closures.
    @discardableResult
    public mutating func clearWithValidator(_ validate: (ShortcutChord?) -> ShortcutValidationError?) -> Bool {
        if let err = validate(nil) {
            refuse(err, chord: nil)
            return false
        }
        shortcut = nil
        unregistered = false
        cancel()
        return true
    }

    public mutating func refuse(_ error: ShortcutValidationError, chord: ShortcutChord? = nil) {
        let existingFinishing = phase.finishingKey
        phase = .capturing(error: error, refused: chord, finishing: existingFinishing)
    }

    /// Pressing a newly added modifier starts a new chord and clears any previous refusal.
    private mutating func hold(_ mods: ShortcutModifiers) {
        let added = mods.subtracting(heldModifiers)
        if !added.isEmpty, case .capturing(_, _, let finishing) = phase {
            phase = .capturing(error: nil, refused: nil, finishing: finishing)
        }
        heldModifiers = mods
    }

    /// Processes a key or modifier event; returns `true` if handled.
    /// `onChange` returns `nil` on success or a `ShortcutValidationError` if rejected.
    @discardableResult
    public mutating func handle(
        _ event: ShortcutInputEvent,
        allowUnmodified: Bool = false,
        onChange: ((ShortcutChord?) -> ShortcutValidationError?)? = nil
    ) -> Bool {
        handleWithValidator(event, allowUnmodified: allowUnmodified) { chord in
            onChange?(chord)
        }
    }

    /// Non-escaping validator variant of `handle(_:...)` so callers can pass `inout State` closures safely.
    @discardableResult
    public mutating func handleWithValidator(
        _ event: ShortcutInputEvent,
        allowUnmodified: Bool = false,
        validate: (ShortcutChord?) -> ShortcutValidationError?
    ) -> Bool {
        switch event {
        case .focusLost:
            let wasActive = isRecording || isSwallowing
            cancel()
            phase = .idle
            return wasActive

        case .modifiersChanged(let mods):
            hold(mods)
            return isRecording

        case let .keyDown(key, mods, isRepeat):
            let lower = key.lowercased()
            hold(mods)
            if phase.finishingKey == lower {
                return true
            }
            if case .swallowing = phase {
                phase = .idle
                return false
            }

            guard isRecording else { return false }
            if isRepeat || Self.isModifierKey(lower) { return true }

            if case .capturing(let err, let ref, _) = phase {
                phase = .capturing(error: err, refused: ref, finishing: lower)
            }

            if lower == "escape" || lower == "esc" {
                cancel()
                return true
            }
            if lower == "backspace" || lower == "delete" {
                if let err = validate(nil) {
                    refuse(err, chord: nil)
                } else {
                    shortcut = nil
                    unregistered = false
                    cancel()
                }
                return true
            }

            let chord = ShortcutChord(key: key, modifiers: mods)
            if !allowUnmodified, case .failure(let err) = chord.requireModifier() {
                refuse(err, chord: chord)
                return true
            }
            if shortcut == chord && !unregistered {
                cancel()
                return true
            }
            if let err = validate(chord) {
                refuse(err, chord: chord)
            } else {
                shortcut = chord
                unregistered = false
                cancel()
            }
            return true

        case .keyUp(let key):
            let lower = key.lowercased()
            if phase.finishingKey == lower {
                switch phase {
                case .capturing(let err, let ref, _):
                    phase = .capturing(error: err, refused: ref, finishing: nil)
                case .swallowing, .idle:
                    phase = .idle
                }
                return true
            }
            return isRecording
        }
    }
}

/// Fluent builder for an interactive shortcut recorder (`rune_kit::shortcut_recorder::ShortcutRecorder`).
public struct ShortcutRecorder<State> {
    public var key: String
    public var stateKeyPath: WritableKeyPath<State, ShortcutRecorderState>
    public var label: String?
    public var width: Float
    public var disabled: Bool
    public var allowUnmodified: Bool
    public var errorFormatter: ((ShortcutValidationError, ShortcutChord?) -> String)?
    public var onChange: ((inout State, ShortcutChord?) -> ShortcutValidationError?)?

    public init(
        key: String = "shortcut-recorder",
        _ stateKeyPath: WritableKeyPath<State, ShortcutRecorderState>,
        label: String? = nil,
        width: Float = 240
    ) {
        self.key = key
        self.stateKeyPath = stateKeyPath
        self.label = label
        self.width = width
        self.disabled = false
        self.allowUnmodified = false
    }

    public func label(_ value: String?) -> Self {
        var copy = self; copy.label = value; return copy
    }

    public func width(_ value: Float) -> Self {
        var copy = self; copy.width = value; return copy
    }

    public func disabled(_ value: Bool = true) -> Self {
        var copy = self; copy.disabled = value; return copy
    }

    public func allowUnmodified(_ value: Bool = true) -> Self {
        var copy = self; copy.allowUnmodified = value; return copy
    }

    public func errorMessage(_ formatter: @escaping (ShortcutValidationError, ShortcutChord?) -> String) -> Self {
        var copy = self; copy.errorFormatter = formatter; return copy
    }

    public func onChange(_ handler: @escaping (inout State, ShortcutChord?) -> ShortcutValidationError?) -> Self {
        var copy = self; copy.onChange = handler; return copy
    }

    public func build(using kit: Kit, in state: State) -> El<State> {
        let rec = state[keyPath: stateKeyPath]
        let errorText: String? = rec.error.map { err in
            errorFormatter?(err, rec.refusedChord) ?? err.defaultMessage(for: rec.refusedChord)
        }
        var elTree: El<State> = kit.shortcutRecorder(
            key: key,
            state: rec,
            label: label,
            width: width,
            disabled: disabled,
            errorText: errorText,
            onBegin: { (s: inout State) in
                s[keyPath: stateKeyPath].begin()
            },
            onClear: { (s: inout State) in
                var recCopy = s[keyPath: stateKeyPath]
                _ = recCopy.clearWithValidator { chord in
                    onChange?(&s, chord)
                }
                s[keyPath: stateKeyPath] = recCopy
            }
        )
        if !disabled {
            elTree = elTree
                .focusable(true)
                .onPhysicalInput { s, ev, tx in
                    guard let mapped = Self.mapPhysicalInput(ev) else { return false }
                    var recCopy = s[keyPath: stateKeyPath]
                    let wasRecording = recCopy.isRecording
                    let handled = recCopy.handleWithValidator(
                        mapped,
                        allowUnmodified: allowUnmodified
                    ) { chord in
                        onChange?(&s, chord)
                    }
                    s[keyPath: stateKeyPath] = recCopy
                    if wasRecording && !recCopy.isRecording {
                        tx.blur()
                    }
                    return handled
                }
                .onKey { s, ev, tx in
                    guard let event = Self.mapKeyEvent(ev) else { return false }
                    var recCopy = s[keyPath: stateKeyPath]
                    let wasRecording = recCopy.isRecording
                    if case .capturing(let err, let ref, _) = recCopy.phase {
                        // El.onKey only delivers keyDown (never keyUp).
                        recCopy.phase = .capturing(error: err, refused: ref, finishing: nil)
                    }
                    let handled = recCopy.handleWithValidator(
                        event,
                        allowUnmodified: allowUnmodified
                    ) { chord in
                        onChange?(&s, chord)
                    }
                    s[keyPath: stateKeyPath] = recCopy
                    if wasRecording && !recCopy.isRecording {
                        tx.blur()
                    }
                    return handled
                }
        }
        return elTree
    }

    static func mapModifiers(_ mods: Mods) -> ShortcutModifiers {
        var out: ShortcutModifiers = []
        if mods.cmd { out.insert(.command) }
        if mods.ctrl { out.insert(.control) }
        if mods.alt { out.insert(.option) }
        if mods.shift { out.insert(.shift) }
        return out
    }

    static func mapPhysicalInput(_ ev: PhysicalInput) -> ShortcutInputEvent? {
        switch ev {
        case .focusLost:
            return .focusLost
        case .modifiers(let mods):
            return .modifiersChanged(mapModifiers(mods))
        case let .key(code, mods, pressed, isRepeat):
            guard let name = mapPhysicalKeyCode(code) else { return nil }
            if pressed {
                return .keyDown(key: name, modifiers: mapModifiers(mods), isRepeat: isRepeat)
            }
            return .keyUp(name)
        }
    }

    static func mapPhysicalKeyCode(_ code: PhysicalKeyCode) -> String? {
        switch code {
        case .keyA: "a"
        case .keyB: "b"
        case .keyC: "c"
        case .keyD: "d"
        case .keyE: "e"
        case .keyF: "f"
        case .keyG: "g"
        case .keyH: "h"
        case .keyI: "i"
        case .keyJ: "j"
        case .keyK: "k"
        case .keyL: "l"
        case .keyM: "m"
        case .keyN: "n"
        case .keyO: "o"
        case .keyP: "p"
        case .keyQ: "q"
        case .keyR: "r"
        case .keyS: "s"
        case .keyT: "t"
        case .keyU: "u"
        case .keyV: "v"
        case .keyW: "w"
        case .keyX: "x"
        case .keyY: "y"
        case .keyZ: "z"
        case .digit0: "0"
        case .digit1: "1"
        case .digit2: "2"
        case .digit3: "3"
        case .digit4: "4"
        case .digit5: "5"
        case .digit6: "6"
        case .digit7: "7"
        case .digit8: "8"
        case .digit9: "9"
        case .escape: "escape"
        case .enter, .numpadEnter: "return"
        case .tab: "tab"
        case .backspace: "backspace"
        case .delete: "delete"
        case .space: "space"
        case .insert: "insert"
        case .minus: "-"
        case .equal: "="
        case .bracketLeft: "["
        case .bracketRight: "]"
        case .backslash: "\\"
        case .semicolon: ";"
        case .quote: "'"
        case .backquote: "`"
        case .comma: ","
        case .period: "."
        case .slash: "/"
        case .capsLock: "capslock"
        case .shiftLeft, .shiftRight: "shift"
        case .controlLeft, .controlRight: "control"
        case .altLeft, .altRight: "option"
        case .superLeft, .superRight: "command"
        case .fn: "fn"
        case .arrowLeft: "left"
        case .arrowRight: "right"
        case .arrowUp: "up"
        case .arrowDown: "down"
        case .home: "home"
        case .end: "end"
        case .pageUp: "pageUp"
        case .pageDown: "pageDown"
        case .f1: "F1"
        case .f2: "F2"
        case .f3: "F3"
        case .f4: "F4"
        case .f5: "F5"
        case .f6: "F6"
        case .f7: "F7"
        case .f8: "F8"
        case .f9: "F9"
        case .f10: "F10"
        case .f11: "F11"
        case .f12: "F12"
        case .f13: "F13"
        case .f14: "F14"
        case .f15: "F15"
        case .f16: "F16"
        case .f17: "F17"
        case .f18: "F18"
        case .f19: "F19"
        case .f20: "F20"
        case .f21: "F21"
        case .f22: "F22"
        case .f23: "F23"
        case .f24: "F24"
        case .numpad0: "0"
        case .numpad1: "1"
        case .numpad2: "2"
        case .numpad3: "3"
        case .numpad4: "4"
        case .numpad5: "5"
        case .numpad6: "6"
        case .numpad7: "7"
        case .numpad8: "8"
        case .numpad9: "9"
        case .numpadAdd: "+"
        case .numpadSubtract: "-"
        case .numpadMultiply: "*"
        case .numpadDivide: "/"
        case .numpadDecimal: "."
        }
    }

    static func mapKeyEvent(_ ev: KeyEvent) -> ShortcutInputEvent? {
        var mods: ShortcutModifiers = []
        if ev.mods.cmd { mods.insert(.command) }
        if ev.mods.ctrl { mods.insert(.control) }
        if ev.mods.alt { mods.insert(.option) }
        if ev.mods.shift { mods.insert(.shift) }

        let keyName: String
        switch ev.key {
        case .escape: keyName = "escape"
        case .backspace: keyName = "backspace"
        case .delete: keyName = "delete"
        case .enter: keyName = "return"
        case .tab: keyName = "tab"
        case .space: keyName = "space"
        case .arrowLeft: keyName = "left"
        case .arrowRight: keyName = "right"
        case .arrowUp: keyName = "up"
        case .arrowDown: keyName = "down"
        case .home: keyName = "home"
        case .end: keyName = "end"
        case .pageUp: keyName = "pageUp"
        case .pageDown: keyName = "pageDown"
        case .f(let n): keyName = "F\(n)"
        case .text(let s):
            if s.isEmpty { return nil }
            keyName = s
        case .command(let ch):
            keyName = String(ch)
        }
        return .keyDown(key: keyName, modifiers: mods, isRepeat: false)
    }
}

extension Kit {
    /// Interactive shortcut recorder using a `ShortcutRecorder<State>` binding builder.
    public func shortcutRecorder<State>(
        key: String = "shortcut-recorder",
        _ stateKeyPath: WritableKeyPath<State, ShortcutRecorderState>,
        in state: State,
        label: String? = nil,
        width: Float = 240,
        disabled: Bool = false,
        allowUnmodified: Bool = false,
        errorMessage: ((ShortcutValidationError, ShortcutChord?) -> String)? = nil,
        onChange: ((inout State, ShortcutChord?) -> ShortcutValidationError?)? = nil
    ) -> El<State> {
        var builder = ShortcutRecorder<State>(key: key, stateKeyPath, label: label, width: width)
            .disabled(disabled)
            .allowUnmodified(allowUnmodified)
        if let errorMessage {
            builder = builder.errorMessage(errorMessage)
        }
        if let onChange {
            builder = builder.onChange(onChange)
        }
        return builder.build(using: self, in: state)
    }

    /// Interactive shortcut recorder capturing key chords with conflict/error badge and clear/escape handling.
    public func shortcutRecorder<State>(
        key: String = "shortcut-recorder",
        state: ShortcutRecorderState,
        label: String? = nil,
        width: Float = 240,
        disabled: Bool = false,
        errorText: String? = nil,
        onBegin: @escaping (inout State) -> Void,
        onClear: ((inout State) -> Void)? = nil
    ) -> El<State> {
        let caps = state.keycaps
        let placeholder = state.isRecording ? "Press shortcut" : "Record shortcut"
        let borderColor: Color = if state.error != nil {
            c.danger.border
        } else if state.isRecording {
            c.borderFocus
        } else {
            c.borderBase
        }

        let contentEl: El<State> = if caps.isEmpty {
            text(placeholder).font(ty.uiCompact).color(c.textFaint)
        } else {
            keybind(caps)
        }

        var control: El<State> = row()
            .key(key)
            .role(.button)
            .w(width)
            .h(32)
            .px(8)
            .itemsCenter()
            .justifyBetween()
            .rounded(radius.md)
            .bg(c.bgBase)
            .border(1.0, borderColor)
            .focusable(!disabled)
            .child(contentEl)

        if let label {
            control = control.label(label)
        } else {
            control = control.label(caps.isEmpty ? placeholder : caps.joined(separator: " "))
        }
        if state.isRecording {
            control = control.help("Press a shortcut. Escape cancels; Backspace clears.")
        }

        if let onClear, state.shortcut != nil, !disabled {
            control = control.child(
                iconButton(key: "\(key)-clear", svg: KitIcons.close, label: "Clear", size: .sm, variant: .ghost) { s, _ in
                    onClear(&s)
                }
            )
        }

        if disabled {
            control = control.inert(true).opacity(0.5)
        } else {
            control = control
                .focusRing(c.borderFocus, offset: 2.0)
                .onClick { s in onBegin(&s) }
        }

        var root: El<State> = col().key("\(key)-field").gap(4).child(control)
        if let err = state.error {
            let resolvedMessage = errorText ?? err.defaultMessage(for: state.refusedChord)
            root = root.child(
                text(resolvedMessage)
                    .key("\(key)-error")
                    .font(ty.smallMedium)
                    .color(c.danger.fg)
            )
        }
        return root
    }
}
