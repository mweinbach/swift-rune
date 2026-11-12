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
        var caps: [String] = []
        if contains(.control) { caps.append("⌃") }
        if contains(.option)  { caps.append("⌥") }
        if contains(.shift)   { caps.append("⇧") }
        if contains(.command) { caps.append("⌘") }
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
        modifiers.keycaps + [key.uppercased()]
    }

    public var displayString: String {
        keycaps.joined()
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
        guard let chord else {
            return self == .invalidKey ? "That key can't be part of a shortcut." : "The shortcut couldn't be cleared."
        }
        let label = chord.displayString
        switch self {
        case .missingModifier: return "Add ⌘, ⌃ or ⌥."
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
    case keyUp(key: String)
}

/// State machine for `ShortcutRecorder` (`rune_kit::shortcut_recorder::ShortcutRecorderState`).
public struct ShortcutRecorderState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case capturing(error: ShortcutValidationError?, refused: ShortcutChord?)
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

    public var isRecording: Bool {
        if case .capturing = phase { return true }
        return false
    }

    public var error: ShortcutValidationError? {
        if case .capturing(let err, _) = phase { return err }
        return nil
    }

    public var refusedChord: ShortcutChord? {
        if case .capturing(_, let chord) = phase { return chord }
        return nil
    }

    public var keycaps: [String] {
        if let refused = refusedChord {
            return refused.keycaps
        }
        if isRecording {
            return heldModifiers.keycaps
        }
        return shortcut?.keycaps ?? []
    }

    public mutating func markUnregistered() {
        unregistered = true
    }

    public mutating func begin() {
        phase = .capturing(error: nil, refused: nil)
    }

    public mutating func cancel() {
        phase = .idle
        heldModifiers = []
    }

    public mutating func refuse(_ error: ShortcutValidationError, chord: ShortcutChord? = nil) {
        phase = .capturing(error: error, refused: chord)
    }

    /// Processes a key or modifier event; returns `true` if handled.
    /// `onChange` returns `nil` on success or a `ShortcutValidationError` if rejected.
    @discardableResult
    public mutating func handle(
        _ event: ShortcutInputEvent,
        allowUnmodified: Bool = false,
        onChange: ((ShortcutChord?) -> ShortcutValidationError?)? = nil
    ) -> Bool {
        switch event {
        case .focusLost:
            let wasActive = isRecording
            cancel()
            return wasActive

        case .modifiersChanged(let mods):
            let added = mods.subtracting(heldModifiers)
            if !added.isEmpty, case .capturing = phase {
                phase = .capturing(error: nil, refused: nil)
            }
            heldModifiers = mods
            return isRecording

        case let .keyDown(key, mods, isRepeat):
            heldModifiers = mods
            guard isRecording else { return false }
            if isRepeat { return true }

            let lower = key.lowercased()
            if lower == "escape" || lower == "esc" {
                cancel()
                return true
            }
            if lower == "backspace" || lower == "delete" {
                if let err = onChange?(nil) {
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
            if let err = onChange?(chord) {
                refuse(err, chord: chord)
            } else {
                shortcut = chord
                unregistered = false
                cancel()
            }
            return true

        case .keyUp:
            return isRecording
        }
    }
}

extension Kit {
    /// Interactive shortcut recorder capturing key chords with conflict/error badge and clear/escape handling.
    public func shortcutRecorder<State>(
        key: String = "shortcut-recorder",
        state: ShortcutRecorderState,
        label: String? = nil,
        width: Float = 240,
        disabled: Bool = false,
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
            .child(contentEl)

        if let label {
            control = control.label(label)
        } else {
            control = control.label(caps.isEmpty ? placeholder : caps.joined(separator: " "))
        }

        if let onClear, state.shortcut != nil, !disabled {
            control = control.child(
                iconButton(key: "\(key)-clear", svg: KitIcons.close, label: "Clear", size: .sm, variant: .ghost) { s, _ in
                    onClear(&s)
                }
            )
        }

        if !disabled {
            control = control.onClick { s in onBegin(&s) }
        }

        var root: El<State> = col().key("\(key)-field").gap(4).child(control)
        if let err = state.error {
            root = root.child(
                text(err.defaultMessage(for: state.refusedChord))
                    .key("\(key)-error")
                    .font(ty.smallMedium)
                    .color(c.danger.fg)
            )
        }
        return root
    }
}
