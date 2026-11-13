import Foundation

#if os(macOS)
import Carbon.HIToolbox
import CoreFoundation
#endif

/// Carbon ANSI virtual keycode & macOS symbolic hotkey mapping (`rune::shortcuts::macos`).
public enum MacOSCarbonKeyMap {
    public static let cmdMask: UInt32 = 1 << 8
    public static let shiftMask: UInt32 = 1 << 9
    public static let optionMask: UInt32 = 1 << 11
    public static let controlMask: UInt32 = 1 << 12
    public static let relevantModifierMask: UInt32 = cmdMask | shiftMask | optionMask | controlMask

    /// Known default macOS symbolic hotkeys: `(symbolicHotkeyId, defaultKeycode, defaultModifiers, ownerName)`.
    public static let knownSystemShortcuts: [(id: String?, keycode: UInt32, mods: UInt32, owner: String)] = [
        ("64", 49, cmdMask, "Spotlight"),
        ("65", 49, cmdMask | optionMask, "Finder search"),
        ("60", 49, controlMask, "Input Sources"),
        ("61", 49, controlMask | optionMask, "Input Sources"),
        ("28", 20, cmdMask | shiftMask, "Screenshot"),
        ("29", 20, controlMask | cmdMask | shiftMask, "Screenshot"),
        ("30", 21, cmdMask | shiftMask, "Screenshot"),
        ("31", 21, controlMask | cmdMask | shiftMask, "Screenshot"),
        ("184", 23, cmdMask | shiftMask, "Screenshot"),
        ("32", 126, controlMask, "Mission Control"),
        ("33", 125, controlMask, "Mission Control"),
        ("79", 123, controlMask, "Mission Control"),
        ("81", 124, controlMask, "Mission Control"),
        (nil, 48, cmdMask, "App Switcher"),
        (nil, 48, cmdMask | shiftMask, "App Switcher"),
    ]

    /// Maps normalized key name or `ChordKey` to physical ANSI Carbon virtual key code.
    public static func keycode(forKeyName name: String) -> UInt32? {
        switch name.lowercased() {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "equal": return 24
        case "9": return 25
        case "7": return 26
        case "minus": return 27
        case "8": return 28
        case "0": return 29
        case "bracketright": return 30
        case "o": return 31
        case "u": return 32
        case "bracketleft": return 33
        case "i": return 34
        case "p": return 35
        case "enter": return 36
        case "l": return 37
        case "j": return 38
        case "quote": return 39
        case "k": return 40
        case "semicolon": return 41
        case "backslash": return 42
        case "comma": return 43
        case "slash": return 44
        case "n": return 45
        case "m": return 46
        case "period": return 47
        case "tab": return 48
        case "space": return 49
        case "backquote": return 50
        case "backspace": return 51
        case "escape": return 53
        case "f17": return 64
        case "f18": return 79
        case "f19": return 80
        case "f20": return 90
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f3": return 99
        case "f8": return 100
        case "f9": return 101
        case "f11": return 103
        case "f13": return 105
        case "f16": return 106
        case "f14": return 107
        case "f10": return 109
        case "f12": return 111
        case "f15": return 113
        case "insert": return 114
        case "home": return 115
        case "pageup": return 116
        case "delete": return 117
        case "f4": return 118
        case "end": return 119
        case "f2": return 120
        case "pagedown": return 121
        case "f1": return 122
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        default: return nil
        }
    }

    /// Maps a `ChordKey` to the Carbon key name expected by `keycode(forKeyName:)`.
    public static func carbonKeyName(for chordKey: ChordKey) -> String? {
        switch chordKey {
        case .char(let ch):
            switch ch {
            case " ": return "space"
            case ",": return "comma"
            case ".": return "period"
            case "-": return "minus"
            case "=": return "equal"
            case "[": return "bracketleft"
            case "]": return "bracketright"
            case "\\": return "backslash"
            case ";": return "semicolon"
            case "'": return "quote"
            case "/": return "slash"
            case "`": return "backquote"
            default: return String(ch).lowercased()
            }
        case .enter: return "enter"
        case .tab: return "tab"
        case .escape: return "escape"
        case .backspace: return "backspace"
        case .delete: return "delete"
        case .insert: return "insert"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageup"
        case .pageDown: return "pagedown"
        case .arrowLeft: return "left"
        case .arrowRight: return "right"
        case .arrowUp: return "up"
        case .arrowDown: return "down"
        case .function(let n): return "f\(n)"
        case .contextMenu, .printScreen, .scrollLock, .pause: return nil
        }
    }

    /// Maps `Mods` on macOS into Carbon modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public static func carbonModifiers(for mods: Mods) -> UInt32 {
        var out: UInt32 = 0
        if mods.cmd || mods.logo { out |= cmdMask }
        if mods.shift { out |= shiftMask }
        if mods.alt { out |= optionMask }
        if mods.ctrl { out |= controlMask }
        return out
    }

    /// Resolves the current macOS keyboard-layout display label for `keyName` under Carbon `modifiers` (`shortcuts/keys.rs:98`).
    public static func displayLabel(for keyName: String, modifiers: UInt32) -> String? {
        guard let code = keycode(forKeyName: keyName),
              let label = MacOSKeyboardLayout.label(key: code, modifiers: modifiers),
              !label.isEmpty else {
            return nil
        }
        return label
    }

    /// Maps `NSEventModifierFlags` bits stored in `com.apple.symbolichotkeys` to Carbon modifier bits.
    public static func carbonModifiers(fromNSEventFlags flags: UInt32) -> UInt32 {
        var out: UInt32 = 0
        if flags & (1 << 17) != 0 { out |= shiftMask }
        if flags & (1 << 18) != 0 { out |= controlMask }
        if flags & (1 << 19) != 0 { out |= optionMask }
        if flags & (1 << 20) != 0 { out |= cmdMask }
        return out
    }

    /// Parses a symbolic-hotkey remap entry `(enabled, keycode, flags)` into `Option<Option<(keycode, mods)>>`.
    public static func parseRemap(enabled: Bool?, keycode: Int64?, flags: Int64?) -> (keycode: UInt32, mods: UInt32)?? {
        if enabled == false {
            return .some(nil)
        }
        guard let keycode, let flags else {
            return nil
        }
        if keycode == 65535 || keycode < 0 {
            return .some(nil)
        }
        return .some((UInt32(keycode), carbonModifiers(fromNSEventFlags: UInt32(truncatingIfNeeded: flags))))
    }

    /// Looks up the human-readable system owner name for `(keycode, carbonMods)`, honoring remappings.
    public static func namedSystemShortcut(
        keycode: UInt32,
        mods: UInt32,
        remapped: [String: (keycode: UInt32, mods: UInt32)?]
    ) -> String? {
        for entry in knownSystemShortcuts {
            let effective: (keycode: UInt32, mods: UInt32)?
            if let id = entry.id, let overrideEntry = remapped[id] {
                effective = overrideEntry
            } else {
                effective = (entry.keycode, entry.mods)
            }
            if let eff = effective, eff.keycode == keycode && eff.mods == mods {
                return entry.owner
            }
        }
        return nil
    }
}

#if os(macOS)

/// Main-thread Carbon `RegisterEventHotKey` global hotkey manager (`rune::shortcuts::macos::Native`).
@MainActor
public final class MacOSGlobalHotKeyBackend {
    private static let signature: OSType = 0x7275_6E65 // 'rune'
    private static let eventHotKeyExistsErr: OSStatus = -9878
    private static let eventNotHandledErr: OSStatus = -9874
    private static let exclusiveOption: OptionBits = 1

    private final class RegistrationContext: @unchecked Sendable {
        var handlersByNumericId: [UInt32: (String, @Sendable () -> Void)] = [:]
        var refById: [String: EventHotKeyRef] = [:]
        var numericIdByStringId: [String: UInt32] = [:]
        var nextNumericId: UInt32 = 1
    }

    private let context = RegistrationContext()
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?

    public init() throws {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(context).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return MacOSGlobalHotKeyBackend.eventNotHandledErr }
            var hkId = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkId
            )
            guard status == noErr, hkId.signature == MacOSGlobalHotKeyBackend.signature else {
                return MacOSGlobalHotKeyBackend.eventNotHandledErr
            }
            let ctx = Unmanaged<RegistrationContext>.fromOpaque(userData).takeUnretainedValue()
            guard let (_, handler) = ctx.handlersByNumericId[hkId.id] else {
                return MacOSGlobalHotKeyBackend.eventNotHandledErr
            }
            handler()
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            userData,
            &eventHandlerRef
        )
        if status != noErr {
            throw ShortcutError.rejectedByOS("Carbon InstallEventHandler failed (\(status))")
        }
    }

    deinit {
        for (_, ref) in context.refById {
            UnregisterEventHotKey(ref)
        }
        context.refById.removeAll()
        context.handlersByNumericId.removeAll()
        context.numericIdByStringId.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    public func register(id: String, chord: Chord, handler: @escaping @Sendable () -> Void) -> Result<Void, ShortcutError> {
        guard let keyName = MacOSCarbonKeyMap.carbonKeyName(for: chord.chordKey),
              let code = MacOSCarbonKeyMap.keycode(forKeyName: keyName) else {
            return .failure(.invalidAccelerator(chord.canonicalString))
        }
        let mods = MacOSCarbonKeyMap.carbonModifiers(for: chord.mods)

        if context.refById[id] != nil {
            _ = unregister(id: id)
        }

        let numericId = context.nextNumericId
        context.nextNumericId &+= 1
        let hkId = EventHotKeyID(signature: Self.signature, id: numericId)
        var outRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            code,
            mods,
            hkId,
            GetApplicationEventTarget(),
            Self.exclusiveOption,
            &outRef
        )
        if status != noErr || outRef == nil {
            if status == Self.eventHotKeyExistsErr {
                let owner = Self.systemOwner(for: chord)
                return .failure(.alreadyInUse(owner: owner))
            }
            return .failure(.rejectedByOS("RegisterEventHotKey failed (\(status))"))
        }
        context.numericIdByStringId[id] = numericId
        context.handlersByNumericId[numericId] = (id, handler)
        context.refById[id] = outRef
        return .success(())
    }

    @discardableResult
    public func unregister(id: String) -> Bool {
        guard let ref = context.refById.removeValue(forKey: id) else {
            return false
        }
        if let numId = context.numericIdByStringId.removeValue(forKey: id) {
            context.handlersByNumericId.removeValue(forKey: numId)
        }
        UnregisterEventHotKey(ref)
        return true
    }

    /// Queries macOS `CopySymbolicHotKeys` + user `AppleSymbolicHotKeys` overrides to identify system owners.
    public static func systemOwner(for chord: Chord) -> String? {
        guard let keyName = MacOSCarbonKeyMap.carbonKeyName(for: chord.chordKey),
              let code = MacOSCarbonKeyMap.keycode(forKeyName: keyName) else { return nil }
        let mods = MacOSCarbonKeyMap.carbonModifiers(for: chord.mods)
        let enabled = enabledSymbolicHotKeys()
        guard enabled.contains(where: { $0.keycode == code && $0.mods == mods }) else {
            return nil
        }
        let remapped = readRemappedSymbolicHotKeys()
        return MacOSCarbonKeyMap.namedSystemShortcut(keycode: code, mods: mods, remapped: remapped) ?? "macOS"
    }

    private static func enabledSymbolicHotKeys() -> [(keycode: UInt32, mods: UInt32)] {
        var unmanagedArray: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanagedArray)
        guard status == noErr, let cfArray = unmanagedArray?.takeRetainedValue() else {
            return []
        }
        guard let dicts = cfArray as? [[String: Any]] else { return [] }
        var result: [(keycode: UInt32, mods: UInt32)] = []
        for d in dicts {
            guard (d["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (d["kHISymbolicHotKeyCode"] as? NSNumber)?.int64Value,
                  code >= 0,
                  let mods = (d["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else {
                continue
            }
            result.append((UInt32(code), mods & MacOSCarbonKeyMap.relevantModifierMask))
        }
        return result
    }

    private static func readRemappedSymbolicHotKeys() -> [String: (keycode: UInt32, mods: UInt32)?] {
        guard let raw = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any] else {
            return [:]
        }
        var out: [String: (keycode: UInt32, mods: UInt32)?] = [:]
        for entry in MacOSCarbonKeyMap.knownSystemShortcuts {
            guard let id = entry.id,
                  let dict = raw[id] as? [String: Any] else { continue }
            let enabled = dict["enabled"] as? Bool
            let params = (dict["value"] as? [String: Any])?["parameters"] as? [NSNumber]
            let keycode = params.flatMap { $0.count > 1 ? $0[1].int64Value : nil }
            let flags = params.flatMap { $0.count > 2 ? $0[2].int64Value : nil }
            if let parsed = MacOSCarbonKeyMap.parseRemap(enabled: enabled, keycode: keycode, flags: flags) {
                out[id] = parsed
            }
        }
        return out
    }
}

#endif
