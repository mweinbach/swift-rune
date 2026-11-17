import Foundation
#if os(macOS)
import Carbon
#endif

// MARK: - 1. Input Time (`rune::input::time`)

/// Event time tracking for input responsiveness measurements (`rune::input::time`).
public enum InputTime {
    private final class State {
        var currentScopeTime: Double?
        var lastTimestamp: Double = 0
    }

    private static let threadKey = "rune.input.time"
    private static var state: State {
        let dictionary = RuneExecutionContext.locals
        if let existing = dictionary[threadKey] as? State { return existing }
        let created = State()
        dictionary[threadKey] = created
        return created
    }

    /// Most recent user input timestamp on this thread (`last_input`).
    public static func lastInput() -> Double {
        state.lastTimestamp
    }

    /// Time of the input event currently being dispatched (`input::time::current`).
    public static func current() -> Double {
        arrival() ?? ProcessInfo.processInfo.systemUptime
    }

    /// The arrival time of the input being dispatched now, `nil` outside every `scope`: work no
    /// input caused (`input::time::current`, which returns `None` there).
    internal static func arrival() -> Double? {
        state.currentScopeTime
    }

    /// Makes `at` the arrival time of what runs now, `nil` for work no input caused, and returns
    /// the one before it, for the caller to put back (`input::time::scope`'s `Scope`, which
    /// unlike `scope(at:)` does not count as the last input).
    @discardableResult
    internal static func swapArrival(_ at: Double?) -> Double? {
        let state = Self.state
        let previous = state.currentScopeTime
        state.currentScopeTime = at
        return previous
    }

    /// Runs `body` with `at` as its arrival time (`None` for work no input caused), as a frame
    /// runs each queued action under its own stamp (`frame.rs`: `input::time::scope(at)`).
    @discardableResult
    internal static func withArrival<T>(_ at: Double?, _ body: () throws -> T) rethrows -> T {
        let previous = swapArrival(at)
        defer { swapArrival(previous) }
        return try body()
    }

    /// The arrival time of a platform event stamped `timestamp` (seconds since boot, as
    /// `NSEvent`/`UIEvent` stamp them), or now when it has none or is stamped after now
    /// (`input::time::arrived` with `native`/`since_boot`).
    internal static func arrival(ofEventStamped timestamp: Double?) -> Double {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let timestamp, timestamp.isFinite, uptime - timestamp > 0 else { return uptime }
        return sinceBoot(now: uptime, uptime: uptime, timestamp: timestamp)
    }

    /// A window took an input event from the platform now: `lastInput` is the moment it was
    /// dispatched, not its arrival stamp, so input dispatched after a frame is always later than
    /// that frame (`input::time::arrived` setting `LAST` to `Instant::now()`).
    internal static func noteDispatched() {
        state.lastTimestamp = ProcessInfo.processInfo.systemUptime
    }

    /// Runs `body` with the current event timestamp bound to `timestamp` (`input::time::scope`).
    public static func scope<T>(at timestamp: Double, _ body: () throws -> T) rethrows -> T {
        state.lastTimestamp = timestamp
        return try withArrival(timestamp, body)
    }

    /// Converts an OS event timestamp (`timestamp`) into the system-uptime clock relative to `now` (`since_boot`).
    public static func sinceBoot(now: Double, uptime: Double, timestamp: Double) -> Double {
        let age = max(0, uptime - timestamp)
        return max(0, now - age)
    }
}

// MARK: - 2. Screencast Keycaps (`rune::input::keycaps`)

/// Screen corner for screencast keycap overlay (`rune::input::keycaps::Corner`).
public enum KeycapsCorner: String, Sendable, Hashable, CaseIterable {
    case bottomLeft = "bottom-left"
    case bottom = "bottom"
    case bottomRight = "bottom-right"
    case topLeft = "top-left"
    case top = "top"
    case topRight = "top-right"

    public static func parse(_ s: String) -> KeycapsCorner? {
        KeycapsCorner(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// One visible keycap badge (`rune::input::keycaps::Cap`).
public struct Keycap: Equatable, Sendable {
    public var id: UInt64
    public var text: String
    public var typing: Bool
    public var count: UInt32
    public var lastTime: Double

    public init(id: UInt64, text: String, typing: Bool, count: UInt32 = 1, lastTime: Double) {
        self.id = id
        self.text = text
        self.typing = typing
        self.count = count
        self.lastTime = lastTime
    }

    /// Rendered pill text (appends ` ×N` on repeated chords, `"␣"` on space-only bursts, and leading `…` on long typing bursts).
    public var label: String {
        if typing {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(repeating: "␣", count: min(text.count, Keycaps.maxTypedChars))
            }
            if text.count > Keycaps.maxTypedChars {
                let suffix = String(text.suffix(Keycaps.maxTypedChars - 1))
                return "…" + suffix
            }
            return text
        }
        if count > 1 {
            return "\(text) ×\(count)"
        }
        return text
    }
}

/// Groups bursts of plain typing and repeats chords into a bounded 3-cap timeline (`Keycaps`).
public struct Keycaps: Sendable {
    public static let holdSeconds: Double = 1.5
    public static let burstGapSeconds: Double = 1.0
    public static let maxShown: Int = 3
    public static let maxTypedChars: Int = 24

    private var caps: [Keycap] = []
    private var nextID: UInt64 = 1

    public init() {}

    public mutating func key(at t: Double, event: KeyEvent) {
        if case .modifier(_, pressed: false) = event.key {
            return
        }
        let (label, typing) = Self.keyLabel(event)
        push(at: t, label: label, typing: typing)
    }

    public mutating func chord(at t: Double, spec: String) {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.lowercased().split(separator: "+").map(String.init)
        var mods = Mods()
        var keyName = ""
        for p in parts {
            switch p {
            case "ctrl", "control": mods.ctrl = true
            case "alt", "option", "opt": mods.alt = true
            case "shift": mods.shift = true
            case "cmd", "mod", "primary":
                #if os(macOS)
                mods.cmd = true
                mods.logo = true
                #else
                mods.ctrl = true
                #endif
            case "super", "win", "logo", "meta", "command":
                mods.logo = true
                mods.cmd = true
            default:
                keyName = p
            }
        }
        let glyphs = Self.modGlyphs(mods) + Self.namedGlyph(keyName)
        push(at: t, label: glyphs, typing: false)
    }

    private mutating func push(at t: Double, label: String, typing: Bool) {
        if let lastIdx = caps.indices.last {
            if typing && caps[lastIdx].typing && (t - caps[lastIdx].lastTime) <= Self.burstGapSeconds {
                caps[lastIdx].text += label
                caps[lastIdx].lastTime = t
                return
            }
            if !typing && !caps[lastIdx].typing && caps[lastIdx].text == label && (t - caps[lastIdx].lastTime) <= Self.holdSeconds {
                caps[lastIdx].count += 1
                caps[lastIdx].lastTime = t
                return
            }
        }
        caps.append(Keycap(id: nextID, text: label, typing: typing, count: 1, lastTime: t))
        nextID &+= 1
    }

    public mutating func visible(at t: Double) -> [Keycap] {
        caps.removeAll { (t - $0.lastTime) >= Self.holdSeconds }
        if caps.count > Self.maxShown {
            return Array(caps.suffix(Self.maxShown))
        }
        return caps
    }

    /// `--keys-theme` parser (`auto` -> `nil`, `light` -> `false`, `dark` -> `true`).
    public static func parseTheme(_ raw: String) -> Bool?? {
        switch raw.lowercased() {
        case "auto": return .some(nil)
        case "light": return .some(false)
        case "dark": return .some(true)
        default: return nil
        }
    }

    /// Apple glyph order `⌃⌥⇧⌘`.
    public static func modGlyphs(_ m: Mods) -> String {
        #if os(macOS)
        let isMac = true
        #else
        let isMac = false
        #endif
        var out = ""
        if m.ctrl || (!isMac && m.cmd) { out += "⌃" }
        if m.alt { out += "⌥" }
        if m.shift { out += "⇧" }
        if m.logo || (isMac && m.cmd) { out += "⌘" }
        return out
    }

    public static func keyLabel(_ ev: KeyEvent) -> (label: String, typing: Bool) {
        let m = ev.mods
        let hasMod = m.cmd || m.ctrl || m.alt || m.logo
        switch ev.key {
        case .text(let s) where !hasMod:
            return (s, true)
        case .text(let s):
            let k = (s == " ") ? "␣" : titleCase(s)
            return (modGlyphs(m) + k, false)
        case .command(let c):
            var mods = m
            mods.cmd = true
            let k = (c == " ") ? "␣" : titleCase(String(c))
            return (modGlyphs(mods) + k, false)
        case .enter: return (modGlyphs(m) + "↩", false)
        case .backspace: return (modGlyphs(m) + "⌫", false)
        case .delete: return (modGlyphs(m) + "⌦", false)
        case .insert: return (modGlyphs(m) + "Ins", false)
        case .arrowLeft: return (modGlyphs(m) + "←", false)
        case .arrowRight: return (modGlyphs(m) + "→", false)
        case .arrowUp: return (modGlyphs(m) + "↑", false)
        case .arrowDown: return (modGlyphs(m) + "↓", false)
        case .home: return (modGlyphs(m) + "↖", false)
        case .end: return (modGlyphs(m) + "↘", false)
        case .pageUp: return (modGlyphs(m) + "⇞", false)
        case .pageDown: return (modGlyphs(m) + "⇟", false)
        case .escape: return (modGlyphs(m) + "⎋", false)
        case .tab: return (modGlyphs(m) + "⇥", false)
        case .space: return hasMod ? (modGlyphs(m) + "␣", false) : (" ", true)
        case .f(let n): return (modGlyphs(m) + "F\(n)", false)
        case .contextMenu: return (modGlyphs(m) + "≣", false)
        case .printScreen: return (modGlyphs(m) + "PrtSc", false)
        case .scrollLock: return (modGlyphs(m) + "ScrLk", false)
        case .pause: return (modGlyphs(m) + "Pause", false)
        case .modifier(let mod, _):
            return (mod == .fn) ? (modGlyphs(m) + "fn", false) : (modGlyphs(m), false)
        }
    }

    public static func namedGlyph(_ name: String) -> String {
        switch name.lowercased() {
        case "space": return "␣"
        case "enter", "return": return "↩"
        case "escape", "esc": return "⎋"
        case "tab": return "⇥"
        case "backspace": return "⌫"
        case "delete", "del": return "⌦"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "home": return "↖"
        case "end": return "↘"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        case "insert": return "Ins"
        case "minus": return "-"
        case "equal": return "="
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "semicolon": return ";"
        case "quote": return "'"
        case "bracketleft": return "["
        case "bracketright": return "]"
        case "backslash": return "\\"
        case "backquote": return "`"
        default: return titleCase(name)
        }
    }

    /// Title-cases keycap names while preserving Turkish dotless `"ı"` and German `"ß"` whose uppercase/lowercase isn't 1:1 roundtrip.
    public static func titleCase(_ name: String) -> String {
        guard let first = name.first else { return "" }
        let upper = String(first).uppercased()
        let firstStr = (upper.lowercased() == String(first)) ? upper : String(first)
        return firstStr + name.dropFirst().lowercased()
    }
}

// MARK: - 3. Balanced Secure Input Claim (`rune::input::secure_input`)

/// Balanced secure event input claim tied to focused password fields (`rune::input::secure_input::SecureInput`).
public final class SecureInputClaim {
    public private(set) var isActive: Bool = false
    private let touchOS: Bool

    public init(touchOS: Bool = false) {
        self.touchOS = touchOS
    }

    public func set(_ active: Bool) {
        guard active != isActive else { return }
        if touchOS {
            #if os(macOS)
            if active {
                isActive = (EnableSecureEventInput() == noErr)
            } else {
                DisableSecureEventInput()
                isActive = false
            }
            #else
            isActive = active
            #endif
        } else {
            isActive = active
        }
    }

    public func windowFocus(_ focused: Bool) {
        if !focused {
            set(false)
        }
    }

    deinit {
        set(false)
    }
}
