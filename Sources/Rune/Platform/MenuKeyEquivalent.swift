import Foundation

/// AppKit `NSEventModifierFlags` bits for menu key equivalents (`native_menu/key_equivalent.rs`).
/// Never includes the function-key flag, which AppKit draws as a globe glyph.
public struct MenuKeyEquivalent: Sendable, Equatable {
    public static let shiftMask: UInt = 1 << 17
    public static let controlMask: UInt = 1 << 18
    public static let optionMask: UInt = 1 << 19
    public static let commandMask: UInt = 1 << 20

    public var key: String
    public var modifierMask: UInt

    public init(key: String, modifierMask: UInt) {
        self.key = key
        self.modifierMask = modifierMask
    }

    public init(chord: Chord) {
        let scalar: UInt32
        switch chord.key {
        case .escape: scalar = 0x1b
        case .enter: scalar = 0x0d
        case .tab: scalar = 9
        case .backspace: scalar = 8
        case .space: scalar = 32
        case .arrowUp: scalar = 0xf700
        case .arrowDown: scalar = 0xf701
        case .arrowLeft: scalar = 0xf702
        case .arrowRight: scalar = 0xf703
        case .insert: scalar = 0xf727
        case .delete: scalar = 0xf728
        case .home: scalar = 0xf729
        case .end: scalar = 0xf72b
        case .pageUp: scalar = 0xf72c
        case .pageDown: scalar = 0xf72d
        case .f(let n) where (1...24).contains(n):
            scalar = 0xf704 + UInt32(n - 1)
        case .command, .text, .f, .contextMenu, .printScreen, .scrollLock, .pause, .modifier:
            scalar = 0
        }

        if scalar != 0, let unicode = UnicodeScalar(scalar) {
            self.key = String(unicode)
        } else {
            switch chord.key {
            case .command(let ch):
                self.key = String(ch).lowercased()
            case .text(let str):
                self.key = str.lowercased()
            default:
                self.key = ""
            }
        }

        self.modifierMask = chord.mods(on: .mac).reduce(into: 0) { mask, modifier in
            switch modifier {
            case .ctrl: mask |= Self.controlMask
            case .alt: mask |= Self.optionMask
            case .shift: mask |= Self.shiftMask
            case .primary, .super: mask |= Self.commandMask
            }
        }
    }

    /// Parses an accelerator string (`"cmd+b"`, `"mod+shift+z"`) into a menu key equivalent.
    public init?(parsing spec: String) {
        guard let chord = Chord(parsing: spec) else { return nil }
        self.init(chord: chord)
    }
}

/// What a standard macOS menu item does (`native_menu/standard.rs`).
public enum StandardMenuRole: String, Sendable, Equatable, CaseIterable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    case minimize
    case close
}

/// Key-down event snapshot as AppKit reports it (`charactersIgnoringModifiers` + modifier flags).
public struct StandardKeyDown: Sendable, Equatable, DefaultInitializable {
    public var chars: String
    public var cmd: Bool
    public var shift: Bool
    public var alt: Bool
    public var ctrl: Bool

    public init() {
        self.chars = ""
        self.cmd = false
        self.shift = false
        self.alt = false
        self.ctrl = false
    }

    public init(chars: String, cmd: Bool = false, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        self.chars = chars
        self.cmd = cmd
        self.shift = shift
        self.alt = alt
        self.ctrl = ctrl
    }
}

public protocol DefaultInitializable {
    init()
}

/// A key equivalent as AppKit matches it (`key` lowercased; uppercase implies `shift`).
public struct StandardEquivalent: Sendable, Equatable, Hashable {
    public var key: String
    public var cmd: Bool
    public var shift: Bool
    public var alt: Bool
    public var ctrl: Bool

    public init?(key: String, cmd: Bool, shift: Bool, alt: Bool, ctrl: Bool) {
        guard !key.isEmpty else { return nil }
        let lower = key.lowercased()
        self.key = lower
        self.cmd = cmd
        self.shift = shift || (lower != key)
        self.alt = alt
        self.ctrl = ctrl
    }
}

/// Routing decision for a standard menu action reaching a Rune view (`native_menu/standard.rs`).
public struct StandardMenuRoute: Sendable, Equatable {
    public var current: Bool
    public var thenButton: Bool

    public init(current: Bool, thenButton: Bool) {
        self.current = current
        self.thenButton = thenButton
    }
}

/// Descriptor for one of the standard Edit / Window items (`native_menu/standard.rs`).
public struct StandardMenuItem: Sendable, Equatable {
    public let role: StandardMenuRole
    public let menu: String
    public let title: String
    public let action: String
    public let key: Character
    public let shift: Bool
    public let separatorBefore: Bool
    public let keyCode: UInt16

    public static let items: [StandardMenuItem] = [
        StandardMenuItem(role: .undo, menu: "Edit", title: "Undo", action: "undo:", key: "z", shift: false, separatorBefore: false, keyCode: 0x06),
        StandardMenuItem(role: .redo, menu: "Edit", title: "Redo", action: "redo:", key: "z", shift: true, separatorBefore: false, keyCode: 0x06),
        StandardMenuItem(role: .cut, menu: "Edit", title: "Cut", action: "cut:", key: "x", shift: false, separatorBefore: true, keyCode: 0x07),
        StandardMenuItem(role: .copy, menu: "Edit", title: "Copy", action: "copy:", key: "c", shift: false, separatorBefore: false, keyCode: 0x08),
        StandardMenuItem(role: .paste, menu: "Edit", title: "Paste", action: "paste:", key: "v", shift: false, separatorBefore: false, keyCode: 0x09),
        StandardMenuItem(role: .selectAll, menu: "Edit", title: "Select All", action: "selectAll:", key: "a", shift: false, separatorBefore: false, keyCode: 0x00),
        StandardMenuItem(role: .minimize, menu: "Window", title: "Minimize", action: "performMiniaturize:", key: "m", shift: false, separatorBefore: false, keyCode: 0x2e),
        StandardMenuItem(role: .close, menu: "Window", title: "Close", action: "performClose:", key: "w", shift: false, separatorBefore: false, keyCode: 0x0d),
    ]

    public static func byAction(_ action: String) -> StandardMenuItem? {
        items.first { $0.action == action }
    }

    public var label: RuneLabel {
        switch role {
        case .undo: return .undo
        case .redo: return .redo
        case .cut: return .cut
        case .copy: return .copy
        case .paste: return .paste
        case .selectAll: return .selectAll
        case .minimize: return .minimize
        case .close: return .close
        }
    }

    public func matches(_ keyDown: StandardKeyDown) -> Bool {
        keyDown.chars.lowercased() == String(self.key)
            && keyDown.cmd
            && keyDown.shift == self.shift
            && !keyDown.alt
            && !keyDown.ctrl
    }

    public var equivalent: StandardEquivalent {
        StandardEquivalent(key: String(key), cmd: true, shift: shift, alt: false, ctrl: false)!
    }

    /// Mac top-level menu placement: App (0), File (1), Edit (2), app menus (3), Window (4), Help (5).
    public static func topIndex(name: String, tops: [String]) -> Int {
        func rank(_ n: String) -> UInt8 {
            switch n {
            case "File": return 1
            case "Edit": return 2
            case "Window": return 4
            case "Help": return 5
            default: return 3
            }
        }
        let targetRank = rank(name)
        if tops.count > 1 {
            for i in 1..<tops.count {
                if rank(tops[i]) > targetRank {
                    return i
                }
            }
        }
        return tops.count
    }

    public func route(hasButton: Bool, current: StandardKeyDown?) -> StandardMenuRoute {
        StandardMenuRoute(
            current: current.map { matches($0) } ?? false,
            thenButton: hasButton && (role == .close || role == .minimize)
        )
    }

    public static func isWinitDefault(topCount: Int, appMenuActions: [String?]) -> Bool {
        topCount == 1
            && appMenuActions.first == .some("orderFrontStandardAboutPanel:")
            && appMenuActions.last == .some("terminate:")
    }
}

/// Platform-agnostic validation and lookup for native menu items (`native_menu/mod.rs`).
public enum NativeMenuValidator {
    public static func validate<State>(_ items: [NativeMenuItem<State>]) throws {
        var ids = Set<String>()
        for item in items {
            if case .named(let title) = item.location,
               title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MenuError.invalid("empty menu title")
            }
            if item.isSeparator { continue }
            if item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MenuError.invalid("empty id or title")
            }
            if !ids.insert(item.id).inserted {
                throw MenuError.invalid("duplicate id \(item.id)")
            }
        }
    }

    public static func lookupIndex<State>(selector: String, in items: [NativeMenuItem<State>]) throws -> Int {
        let nonSep = items.enumerated().filter { !$0.element.isSeparator }
        let index: Int
        if let byId = nonSep.first(where: { $0.element.id == selector }) {
            index = byId.offset
        } else {
            let matches = nonSep.filter { $0.element.title == selector }
            guard let first = matches.first else {
                throw MenuError.unknownItem(selector)
            }
            if matches.count > 1 {
                throw MenuError.ambiguousTitle(selector)
            }
            index = first.offset
        }
        guard items[index].enabled else {
            throw MenuError.disabled(selector)
        }
        return index
    }
}

extension Chord {
    /// Logical keycaps matching menu accelerators (`Shortcut::menu_keycaps`, independent of keyboard layout).
    public func menuKeycaps(on platform: KeyPlatform = .current) -> [String] {
        var caps: [String] = mods(on: platform).map { mod in
            switch (mod, platform) {
            case (.primary, .mac), (.super, .mac): return "⌘"
            case (.ctrl, .mac): return "⌃"
            case (.alt, .mac): return "⌥"
            case (.shift, .mac): return "⇧"
            case (.primary, _), (.ctrl, _): return "Ctrl"
            case (.alt, _): return "Alt"
            case (.shift, _): return "Shift"
            case (.super, .windows): return "Win"
            case (.super, .linux): return "Super"
            }
        }
        let mac = platform.isMac
        let keyString: String
        switch chordKey {
        case .char(" "): keyString = "Space"
        case .char(let c): keyString = String(c).uppercased()
        case .enter: keyString = mac ? "↩" : "Enter"
        case .tab: keyString = mac ? "⇥" : "Tab"
        case .escape: keyString = mac ? "⎋" : "Esc"
        case .backspace: keyString = mac ? "⌫" : "Backspace"
        case .delete: keyString = mac ? "⌦" : "Delete"
        case .insert: keyString = "Insert"
        case .home: keyString = mac ? "↖" : "Home"
        case .end: keyString = mac ? "↘" : "End"
        case .pageUp: keyString = mac ? "⇞" : (platform == .linux ? "PageUp" : "Page Up")
        case .pageDown: keyString = mac ? "⇟" : (platform == .linux ? "PageDown" : "Page Down")
        case .arrowLeft: keyString = mac ? "←" : "Left"
        case .arrowRight: keyString = mac ? "→" : "Right"
        case .arrowUp: keyString = mac ? "↑" : "Up"
        case .arrowDown: keyString = mac ? "↓" : "Down"
        case .function(let n): keyString = "F\(n)"
        case .contextMenu: keyString = "Menu"
        case .printScreen: keyString = "Print Screen"
        case .scrollLock: keyString = "Scroll Lock"
        case .pause: keyString = "Pause"
        }
        caps.append(keyString)
        return caps
    }
}
