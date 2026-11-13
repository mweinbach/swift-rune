import Foundation

/// The platform whose keyboard conventions a chord resolves and draws with (`rune::KeyPlatform`).
public enum KeyPlatform: String, Sendable, Hashable, Codable {
    case mac
    case windows
    case linux

    /// The platform this build runs on.
    public static var current: KeyPlatform {
        #if os(macOS) || os(iOS)
        return .mac
        #elseif os(windows)
        return .windows
        #else
        return .linux
        #endif
    }

    internal var isMac: Bool { self == .mac }
}

/// One modifier as a chord names it (`rune::ChordMod`).
public enum ChordMod: Sendable, Hashable {
    /// `"mod"` / `"primary"`: ⌘ on macOS, Ctrl elsewhere.
    case primary
    /// `"ctrl"` / `"control"`: Ctrl key. Off macOS it equals `.primary`.
    case ctrl
    /// `"alt"` / `"opt"` / `"option"`: Option on macOS.
    case alt
    case shift
    /// `"super"` / `"cmd"` / `"command"` / `"meta"` / `"win"` / `"logo"`: ⌘ on macOS (where it equals `.primary`).
    case `super`

    internal var bit: UInt8 {
        switch self {
        case .primary: return ChordBits.primary
        case .ctrl: return ChordBits.ctrl
        case .alt: return ChordBits.alt
        case .shift: return ChordBits.shift
        case .super: return ChordBits.super
        }
    }
}

/// The key a chord ends in (`rune::ChordKey`).
public enum ChordKey: Sendable, Hashable {
    case char(Character)
    case enter
    case tab
    case escape
    case backspace
    case delete
    case insert
    case home
    case end
    case pageUp
    case pageDown
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case function(UInt8)
    case contextMenu
    case printScreen
    case scrollLock
    case pause
}

/// Which side of a modifier pair (`rune::KeySide`).
public enum KeySide: Sendable, Hashable {
    case left
    case right
}

/// A modifier key by side (`rune::Modifier`).
public enum ModifierKey: Sendable, Hashable {
    case shiftLeft
    case shiftRight
    case controlLeft
    case controlRight
    case altLeft
    case altRight
    case superLeft
    case superRight
    case fn

    public var side: KeySide? {
        switch self {
        case .shiftLeft, .controlLeft, .altLeft, .superLeft: return .left
        case .shiftRight, .controlRight, .altRight, .superRight: return .right
        case .fn: return nil
        }
    }
}

/// Errors reported by strict `Chord.parse(_:)` (`rune::ChordError`).
public enum ChordError: Error, Sendable, Equatable {
    case empty
    case trailingPlus
    case noKey
    case duplicateModifier(String)
    case unknownModifier(String)
    case unknownKey(String)
}

internal enum ChordBits {
    static let primary: UInt8 = 1
    static let ctrl: UInt8 = 2
    static let alt: UInt8 = 4
    static let shift: UInt8 = 8
    static let `super`: UInt8 = 16

    /// Merges the platform-equivalent modifier (`super` -> `primary` on macOS, `ctrl` -> `primary` elsewhere).
    static func fold(_ bits: UInt8, platform: KeyPlatform) -> UInt8 {
        let same = platform.isMac ? Self.super : Self.ctrl
        return (bits & same) != 0 ? (bits & ~same) | Self.primary : bits
    }

    /// Resolves `Mods` to chord modifier bits on `platform`, accepting both real macOS events
    /// (`Mods(cmd: true, logo: true)`) and bare script/test events (`Mods(cmd: true)`).
    static func held(_ m: Mods, platform: KeyPlatform) -> UInt8 {
        let bare = m.cmd && !m.ctrl && !m.logo
        let ctrl: Bool
        let logo: Bool
        if bare {
            ctrl = m.ctrl
            logo = m.logo
        } else {
            #if os(macOS)
            ctrl = m.ctrl
            logo = m.logo || m.cmd
            #else
            ctrl = m.ctrl || m.cmd
            logo = m.logo
            #endif
        }
        let ctrlBit = platform.isMac ? Self.ctrl : Self.primary
        let logoBit = platform.isMac ? Self.primary : Self.super
        var bits: UInt8 = 0
        if bare { bits |= Self.primary }
        if ctrl { bits |= ctrlBit }
        if logo { bits |= logoBit }
        if m.alt { bits |= Self.alt }
        if m.shift { bits |= Self.shift }
        return bits
    }

    static func modsFromBits(_ bits: UInt8, platform: KeyPlatform) -> Mods {
        let folded = fold(bits, platform: platform)
        var m = Mods()
        if (folded & Self.shift) != 0 { m.shift = true }
        if (folded & Self.alt) != 0 { m.alt = true }
        if (folded & Self.ctrl) != 0 { m.ctrl = true }
        if (folded & Self.super) != 0 { m.logo = true }
        if (folded & Self.primary) != 0 {
            if platform.isMac {
                m.cmd = true
                m.logo = true
            } else {
                m.cmd = true
                m.ctrl = true
            }
        }
        return m
    }

    static func bitsFromMods(_ m: Mods) -> UInt8 {
        var bits: UInt8 = 0
        if m.shift { bits |= Self.shift }
        if m.alt { bits |= Self.alt }
        if m.ctrl { bits |= Self.ctrl }
        if m.logo { bits |= Self.super }
        if m.cmd && !m.ctrl && !m.logo {
            bits |= Self.primary
        } else if m.cmd {
            #if os(macOS) || os(iOS)
            bits |= Self.primary
            #else
            bits |= Self.ctrl
            #endif
        }
        return bits
    }
}

internal enum ChordTable {
    static func lowerChar(_ c: Character) -> Character {
        let s = String(c).lowercased()
        return s.count == 1 ? (s.first ?? c) : c
    }

    static func modifierNamed(_ name: String) -> ChordMod? {
        switch name.lowercased() {
        case "mod", "primary": return .primary
        case "ctrl", "control": return .ctrl
        case "alt", "option", "opt": return .alt
        case "shift": return .shift
        case "super", "cmd", "command", "meta", "win", "logo": return .super
        default: return nil
        }
    }

    static func charNamed(_ name: String) -> Character? {
        switch name.lowercased() {
        case "space": return " "
        case "plus": return "+"
        case "comma": return ","
        case "minus": return "-"
        case "equal": return "="
        case "period": return "."
        case "slash": return "/"
        case "backslash": return "\\"
        case "backquote": return "`"
        case "semicolon": return ";"
        case "quote": return "'"
        case "bracketleft": return "["
        case "bracketright": return "]"
        default: return nil
        }
    }

    static func charToken(_ c: Character) -> String {
        switch c {
        case " ": return "space"
        case "+": return "plus"
        case ",": return "comma"
        case "-": return "minus"
        case "=": return "equal"
        case ".": return "period"
        case "/": return "slash"
        case "\\": return "backslash"
        case "`": return "backquote"
        case ";": return "semicolon"
        case "'": return "quote"
        case "[": return "bracketleft"
        case "]": return "bracketright"
        default: return String(c)
        }
    }

    static func usUnshifted(_ c: Character) -> Character? {
        let shifted = Array("~!@#$%^&*()_+{}|:\"<>?")
        let plain = Array("`1234567890-=[]\\;',./")
        guard let idx = shifted.firstIndex(of: c) else { return nil }
        return plain[idx]
    }

    static func chordKey(named raw: String) -> ChordKey? {
        let lower = raw.lowercased()
        switch lower {
        case "enter", "return": return .enter
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "backspace": return .backspace
        case "delete", "del": return .delete
        case "insert", "ins": return .insert
        case "home": return .home
        case "end": return .end
        case "pageup", "pgup": return .pageUp
        case "pagedown", "pgdn": return .pageDown
        case "left", "arrowleft": return .arrowLeft
        case "right", "arrowright": return .arrowRight
        case "up", "arrowup": return .arrowUp
        case "down", "arrowdown": return .arrowDown
        case "contextmenu", "menu": return .contextMenu
        case "printscreen", "prtsc": return .printScreen
        case "scrolllock": return .scrollLock
        case "pause", "break": return .pause
        default:
            if let ch = charNamed(lower) {
                return .char(ch)
            }
            if lower.hasPrefix("f") {
                let rest = lower.dropFirst()
                if !rest.hasPrefix("0"), !rest.hasPrefix("+"), let n = UInt8(rest), (1...24).contains(n) {
                    return .function(n)
                }
            }
            if raw.count == 1, let ch = raw.first {
                return .char(lowerChar(ch))
            }
            return nil
        }
    }

    static func chordKey(from key: Key) -> ChordKey? {
        switch key {
        case .command(let ch): return .char(lowerChar(ch))
        case .text(let s):
            guard s.count == 1, let ch = s.first else { return nil }
            return .char(lowerChar(ch))
        case .enter: return .enter
        case .tab: return .tab
        case .escape: return .escape
        case .backspace: return .backspace
        case .delete: return .delete
        case .insert: return .insert
        case .space: return .char(" ")
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .f(let n): return .function(n)
        case .contextMenu: return .contextMenu
        case .printScreen: return .printScreen
        case .scrollLock: return .scrollLock
        case .pause: return .pause
        case .modifier: return nil
        }
    }

    static func key(from chordKey: ChordKey, hasPrimary: Bool) -> Key {
        switch chordKey {
        case .char(" "): return .space
        case .char(let ch): return hasPrimary ? .command(ch) : .text(String(ch))
        case .enter: return .enter
        case .tab: return .tab
        case .escape: return .escape
        case .backspace: return .backspace
        case .delete: return .delete
        case .insert: return .insert
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .function(let n): return .f(n)
        case .contextMenu: return .contextMenu
        case .printScreen: return .printScreen
        case .scrollLock: return .scrollLock
        case .pause: return .pause
        }
    }
}

extension Mods {
    /// Whether the platform's primary modifier (and no other except Shift), or bare `Key.command`, is held (`chord::primary_alone`).
    public var primaryAlone: Bool {
        let bits = ChordBits.held(self, platform: .current) & ~ChordBits.shift
        return bits == 0 || bits == ChordBits.primary
    }
}

extension KeyEvent {
    /// True when `key` types `ch` (case-insensitively) as either `.command(ch)` or `.text`.
    public func isCommand(_ ch: Character) -> Bool {
        let target = ChordTable.lowerChar(ch)
        switch key {
        case .command(let c):
            return ChordTable.lowerChar(c) == target
        case .text(let s):
            return s.count == 1 && ChordTable.lowerChar(s.first!) == target
        default:
            return false
        }
    }

    /// True when the event is a primary-command shortcut or macOS Control binding (`KeyEvent::is_command`).
    public var isCommandChord: Bool {
        if mods.primaryCommand { return true }
        #if os(macOS) || os(iOS)
        return mods.ctrl && !mods.alt && !mods.cmd && !mods.logo && controlBinding != nil
        #else
        return false
        #endif
    }

    /// ASCII Emacs/macOS Control binding letter (`Ctrl-A`, `Ctrl-E`, `Ctrl-B`, `Ctrl-F`, `Ctrl-P`, `Ctrl-N`, `Ctrl-D`, `Ctrl-H`, `Ctrl-K`), or `nil`.
    public var controlBinding: Character? {
        #if os(macOS) || os(iOS)
        guard mods.ctrl && !mods.alt && !mods.cmd && !mods.logo else { return nil }
        let letter: Character?
        switch key {
        case .command(let c):
            letter = ChordTable.lowerChar(c)
        case .text(let s) where s.count == 1:
            let ch = s.first!
            if let scalar = ch.unicodeScalars.first, scalar.value >= 1 && scalar.value <= 26 {
                letter = Character(UnicodeScalar(scalar.value + 96)!)
            } else {
                letter = ChordTable.lowerChar(ch)
            }
        default:
            letter = nil
        }
        guard let ch = letter, ["a", "e", "b", "f", "p", "n", "d", "h", "k"].contains(ch) else {
            return nil
        }
        return ch
        #else
        return nil
        #endif
    }
}
