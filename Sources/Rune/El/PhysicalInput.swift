import Foundation

/// Physical keyboard key identifier mirroring `rune::PhysicalKeyCode` (`winit::keyboard::KeyCode`).
public enum PhysicalKeyCode: String, Sendable, Hashable, Codable {
    case keyA, keyB, keyC, keyD, keyE, keyF, keyG, keyH, keyI, keyJ, keyK, keyL, keyM
    case keyN, keyO, keyP, keyQ, keyR, keyS, keyT, keyU, keyV, keyW, keyX, keyY, keyZ
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
    case escape, enter, tab, backspace, space, insert, delete
    case minus, equal, bracketLeft, bracketRight, backslash, semicolon, quote, backquote, comma, period, slash
    case capsLock, shiftLeft, shiftRight, controlLeft, controlRight, altLeft, altRight, superLeft, superRight, fn
    case arrowLeft, arrowRight, arrowUp, arrowDown, home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24
    case numpad0, numpad1, numpad2, numpad3, numpad4, numpad5, numpad6, numpad7, numpad8, numpad9
    case numpadAdd, numpadSubtract, numpadMultiply, numpadDivide, numpadDecimal, numpadEnter

    /// Best-effort conversion from a logical `Key` for US layout callers/tests.
    public static func from(_ key: Key) -> PhysicalKeyCode? {
        switch key {
        case .enter: return .enter
        case .tab: return .tab
        case .escape: return .escape
        case .backspace: return .backspace
        case .delete: return .delete
        case .space: return .space
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .f(let n):
            switch n {
            case 1: return .f1; case 2: return .f2; case 3: return .f3; case 4: return .f4
            case 5: return .f5; case 6: return .f6; case 7: return .f7; case 8: return .f8
            case 9: return .f9; case 10: return .f10; case 11: return .f11; case 12: return .f12
            case 13: return .f13; case 14: return .f14; case 15: return .f15; case 16: return .f16
            case 17: return .f17; case 18: return .f18; case 19: return .f19; case 20: return .f20
            case 21: return .f21; case 22: return .f22; case 23: return .f23; case 24: return .f24
            default: return nil
            }
        case .command(let ch):
            return Self.fromChar(ch)
        case .text(let s) where s.count == 1:
            return Self.fromChar(s.first!)
        default:
            return nil
        }
    }

    private static func fromChar(_ ch: Character) -> PhysicalKeyCode? {
        switch ch.lowercased() {
        case "a": return .keyA; case "b": return .keyB; case "c": return .keyC; case "d": return .keyD
        case "e": return .keyE; case "f": return .keyF; case "g": return .keyG; case "h": return .keyH
        case "i": return .keyI; case "j": return .keyJ; case "k": return .keyK; case "l": return .keyL
        case "m": return .keyM; case "n": return .keyN; case "o": return .keyO; case "p": return .keyP
        case "q": return .keyQ; case "r": return .keyR; case "s": return .keyS; case "t": return .keyT
        case "u": return .keyU; case "v": return .keyV; case "w": return .keyW; case "x": return .keyX
        case "y": return .keyY; case "z": return .keyZ
        case "0": return .digit0; case "1": return .digit1; case "2": return .digit2; case "3": return .digit3
        case "4": return .digit4; case "5": return .digit5; case "6": return .digit6; case "7": return .digit7
        case "8": return .digit8; case "9": return .digit9
        case " ": return .space
        case "-": return .minus; case "=": return .equal; case "[": return .bracketLeft; case "]": return .bracketRight
        case "\\": return .backslash; case ";": return .semicolon; case "'": return .quote; case "`": return .backquote
        case ",": return .comma; case ".": return .period; case "/": return .slash
        default: return nil
        }
    }
}

/// Physical keyboard/modifier/focus input delivered before logical editing and focus navigation
/// (`crates/rune/src/input/physical_input.rs`).
public enum PhysicalInput: Sendable, Hashable {
    case key(key: PhysicalKeyCode, mods: Mods, pressed: Bool, repeat: Bool)
    case modifiers(Mods)
    case focusLost
}
