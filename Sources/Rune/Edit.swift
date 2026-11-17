import Foundation

/// Keyboard modifier flags (`rune::Mods`).
public struct Mods: Sendable, Hashable, Codable {
    public var shift: Bool
    public var ctrl: Bool
    public var alt: Bool
    public var cmd: Bool
    public var logo: Bool

    public init(
        shift: Bool = false,
        ctrl: Bool = false,
        alt: Bool = false,
        cmd: Bool = false,
        logo: Bool = false
    ) {
        self.shift = shift
        self.ctrl = ctrl
        self.alt = alt
        self.cmd = cmd
        self.logo = logo
    }

    public static let none = Mods()

    /// Platform primary shortcut modifier (`cmd` on macOS/iOS, `ctrl` elsewhere).
    public var primaryCommand: Bool {
        #if os(macOS) || os(iOS)
        return cmd
        #else
        return ctrl
        #endif
    }
}

/// Logical key identifier (`rune::Key`).
public enum Key: Sendable, Hashable {
    case text(String)
    case command(Character)
    case enter
    case tab
    case escape
    case backspace
    case delete
    case insert
    case space
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case home
    case end
    case pageUp
    case pageDown
    case f(UInt8)
    case contextMenu
    case printScreen
    case scrollLock
    case pause
    case modifier(ModifierKey, pressed: Bool)

    public static func named(_ raw: String) -> Key? {
        guard let ck = ChordTable.chordKey(named: raw) else { return nil }
        return ChordTable.key(from: ck, hasPrimary: false)
    }
}

/// Keyboard press/release event (`rune::KeyEvent`).
public struct KeyEvent: Sendable, Hashable {
    public var key: Key
    public var mods: Mods

    public init(key: Key, mods: Mods = .none) {
        self.key = key
        self.mods = mods
    }
}

/// Parsed keyboard shortcut chord (`"mod+shift+k"`, `"cmd+s"`, `"escape"`, `"alt+up"`).
public struct Chord: Sendable, Hashable, CustomStringConvertible {
    public var mods: Mods
    public var key: Key
    internal let chordModBits: UInt8
    public let chordKey: ChordKey

    public static func == (lhs: Chord, rhs: Chord) -> Bool {
        lhs.chordModBits == rhs.chordModBits && lhs.chordKey == rhs.chordKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(chordModBits)
        hasher.combine(chordKey)
    }

    public init(mods: Mods = .none, key: Key) {
        self.chordModBits = ChordBits.bitsFromMods(mods)
        self.chordKey = ChordTable.chordKey(from: key) ?? .escape
        self.mods = mods
        self.key = key
    }

    public init(chordMods: [ChordMod], key chordKey: ChordKey, platform: KeyPlatform = .current) {
        let bits = chordMods.reduce(UInt8(0)) { $0 | $1.bit }
        self.chordModBits = bits
        self.chordKey = chordKey
        let resolvedMods = ChordBits.modsFromBits(bits, platform: platform)
        self.mods = resolvedMods
        let hasPrimary = (ChordBits.fold(bits, platform: platform) & ChordBits.primary) != 0
        self.key = ChordTable.key(from: chordKey, hasPrimary: hasPrimary)
    }

    /// Parses `spec` with platform-specific `mod` resolution (`chord.rs:248`, `KeyPlatform`).
    public static func parse(_ spec: String, platform: KeyPlatform) throws -> Chord {
        let parsed = try parse(spec)
        var list: [ChordMod] = []
        if (parsed.chordModBits & ChordBits.primary) != 0 { list.append(.primary) }
        if (parsed.chordModBits & ChordBits.ctrl) != 0 { list.append(.ctrl) }
        if (parsed.chordModBits & ChordBits.alt) != 0 { list.append(.alt) }
        if (parsed.chordModBits & ChordBits.shift) != 0 { list.append(.shift) }
        if (parsed.chordModBits & ChordBits.super) != 0 { list.append(.super) }
        return Chord(chordMods: list, key: parsed.chordKey, platform: platform)
    }

    /// Parses a comma-separated chord list (`""` or `"none"` returns `[]`, matching `chord::parse_list`).
    public static func parseList(_ spec: String, platform: KeyPlatform = .current) throws -> [Chord] {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "none" {
            return []
        }
        var out: [Chord] = []
        for rawPart in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let part = String(rawPart).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(try parse(part, platform: platform))
        }
        return out
    }

    /// Strictly parses a chord string (`"mod+shift+t"`, `"cmd+s"`, `"mod++"`, `"super+space"`), throwing `ChordError` on invalid input.
    public static func parse(_ spec: String) throws -> Chord {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChordError.empty }

        let modifierTokens: [String]
        let keyToken: String
        if trimmed == "+" {
            modifierTokens = []
            keyToken = "+"
        } else if trimmed.hasSuffix("+") {
            let beforeFinalPlus = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
            guard beforeFinalPlus.hasSuffix("+") else {
                throw ChordError.trailingPlus
            }
            let modsPart = String(beforeFinalPlus.dropLast())
            if modsPart.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ChordError.unknownModifier("")
            }
            modifierTokens = modsPart.split(separator: "+", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            keyToken = "+"
        } else {
            let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard let last = parts.last, !last.isEmpty else { throw ChordError.noKey }
            modifierTokens = Array(parts.dropLast())
            keyToken = last
        }

        var bits: UInt8 = 0
        for p in modifierTokens {
            guard !p.isEmpty else { throw ChordError.unknownModifier("") }
            guard let cm = ChordTable.modifierNamed(p) else {
                throw ChordError.unknownModifier(p)
            }
            guard (bits & cm.bit) == 0 else {
                throw ChordError.duplicateModifier(p)
            }
            bits |= cm.bit
        }

        guard var parsedChordKey = ChordTable.chordKey(named: keyToken) else {
            throw ChordError.unknownKey(keyToken)
        }
        // Per upstream chord.rs:135-136: only '{' and '}' fold unconditionally to Shift + '[' / ']'.
        if case .char(let ch) = parsedChordKey, ch == "{" || ch == "}" {
            parsedChordKey = (ch == "{") ? .char("[") : .char("]")
            bits |= ChordBits.shift
        }

        var modsList: [ChordMod] = []
        if (bits & ChordBits.primary) != 0 { modsList.append(.primary) }
        if (bits & ChordBits.ctrl) != 0 { modsList.append(.ctrl) }
        if (bits & ChordBits.alt) != 0 { modsList.append(.alt) }
        if (bits & ChordBits.shift) != 0 { modsList.append(.shift) }
        if (bits & ChordBits.super) != 0 { modsList.append(.super) }
        return Chord(chordMods: modsList, key: parsedChordKey)
    }

    public init?(parsing spec: String) {
        guard let parsed = try? Chord.parse(spec) else { return nil }
        self = parsed
    }

    public func matches(_ ev: KeyEvent) -> Bool {
        matches(ev, on: .current)
    }

    public func matches(_ ev: KeyEvent, on platform: KeyPlatform) -> Bool {
        let want = ChordBits.fold(chordModBits, platform: platform)
        let got = ChordBits.held(ev.mods, platform: platform)
        guard let gotKey = ChordTable.chordKey(from: ev.key) else { return false }
        if want == got && gotKey == chordKey {
            return true
        }
        // Fallback 1 (chord.rs:214): Shift+[ / Shift+{ — event carries Shift and typed a US shifted char.
        if want == got, ev.mods.shift, case .char(let typed) = gotKey,
           let unshifted = ChordTable.usUnshifted(typed), .char(unshifted) == chordKey {
            return true
        }
        // Fallback 2 (chord.rs:219): OS delivered Shift alongside non-alphanumeric shifted char (e.g. mod+plus vs Shift+=).
        if (want | ChordBits.shift) == got,
           case .char(let ch) = chordKey,
           !ch.isLetter, !ch.isNumber,
           gotKey == .char(ch) {
            return true
        }
        return false
    }

    public func sameKeys(_ other: Chord, on platform: KeyPlatform = .current) -> Bool {
        ChordBits.fold(chordModBits, platform: platform) == ChordBits.fold(other.chordModBits, platform: platform)
            && chordKey == other.chordKey
    }

    public func mods(on platform: KeyPlatform = .current) -> [ChordMod] {
        let bits = ChordBits.fold(chordModBits, platform: platform)
        let order: [ChordMod] = platform.isMac
            ? [.ctrl, .alt, .shift, .primary, .super]
            : [.primary, .ctrl, .alt, .shift, .super]
        return order.filter { (bits & $0.bit) != 0 }
    }

    public func keycaps(on platform: KeyPlatform = .current) -> [String] {
        var caps: [String] = mods(on: platform).map { mod in
            switch (mod, platform) {
            case (.primary, .mac): return "⌘"
            case (.ctrl, .mac): return "⌃"
            case (.alt, .mac): return "⌥"
            case (.shift, .mac): return "⇧"
            case (.super, .mac): return "⌘"
            case (.primary, _), (.ctrl, _): return "Ctrl"
            case (.alt, _): return "Alt"
            case (.shift, _): return "Shift"
            case (.super, .windows): return "Win"
            case (.super, .linux): return "Super"
            }
        }
        if platform.isMac,
           case .char(let ch) = chordKey,
           let keyName = MacOSCarbonKeyMap.carbonKeyName(for: .char(ch)),
           let translated = MacOSCarbonKeyMap.displayLabel(
               for: keyName,
               modifiers: MacOSCarbonKeyMap.carbonModifiers(for: mods(on: .mac).reduce(into: Mods.none) { acc, m in
                   switch m {
                   case .primary, .super: acc.cmd = true
                   case .ctrl: acc.ctrl = true
                   case .alt: acc.alt = true
                   case .shift: acc.shift = true
                   }
               })
           ) {
            caps.append(translated.uppercased())
        } else {
            caps.append(Self.keycapString(chordKey, platform: platform))
        }
        return caps
    }

    public func label(on platform: KeyPlatform = .current) -> String {
        keycaps(on: platform).joined(separator: platform.isMac ? "" : "+")
    }

    public var canonicalString: String {
        var parts: [String] = []
        if (chordModBits & ChordBits.primary) != 0 { parts.append("mod") }
        if (chordModBits & ChordBits.ctrl) != 0 { parts.append("ctrl") }
        if (chordModBits & ChordBits.alt) != 0 { parts.append("alt") }
        if (chordModBits & ChordBits.shift) != 0 { parts.append("shift") }
        if (chordModBits & ChordBits.super) != 0 { parts.append("super") }
        parts.append(Self.canonicalKeyToken(chordKey))
        return parts.joined(separator: "+")
    }

    public var description: String {
        var parts: [String] = []
        let active = mods(on: .current)
        if active.contains(.ctrl) { parts.append("Ctrl") }
        if active.contains(.alt) { parts.append("Alt") }
        if active.contains(.shift) { parts.append("Shift") }
        if active.contains(.primary) || active.contains(.super) {
            #if os(macOS) || os(iOS)
            parts.append("Cmd")
            #else
            parts.append(active.contains(.super) ? "Super" : "Ctrl")
            #endif
        }
        parts.append(Self.keycapString(chordKey, platform: .linux))
        return parts.joined(separator: "+")
    }

    private static func canonicalKeyToken(_ ck: ChordKey) -> String {
        switch ck {
        case .char(let c): return ChordTable.charToken(c)
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
        case .contextMenu: return "contextmenu"
        case .printScreen: return "printscreen"
        case .scrollLock: return "scrolllock"
        case .pause: return "pause"
        }
    }

    private static func keycapString(_ ck: ChordKey, platform: KeyPlatform) -> String {
        let mac = platform.isMac
        switch ck {
        case .char(" "): return "Space"
        case .char(let c): return String(c).uppercased()
        case .enter: return mac ? "↩" : "Enter"
        case .tab: return mac ? "⇥" : "Tab"
        case .escape: return mac ? "⎋" : "Esc"
        case .backspace: return mac ? "⌫" : "Backspace"
        case .delete: return mac ? "⌦" : "Delete"
        case .insert: return "Insert"
        case .home: return mac ? "↖" : "Home"
        case .end: return mac ? "↘" : "End"
        case .pageUp: return mac ? "⇞" : (platform == .linux ? "PageUp" : "Page Up")
        case .pageDown: return mac ? "⇟" : (platform == .linux ? "PageDown" : "Page Down")
        case .arrowLeft: return mac ? "←" : "Left"
        case .arrowRight: return mac ? "→" : "Right"
        case .arrowUp: return mac ? "↑" : "Up"
        case .arrowDown: return mac ? "↓" : "Down"
        case .function(let n): return "F\(n)"
        case .contextMenu: return "Menu"
        case .printScreen: return "Print Screen"
        case .scrollLock: return "Scroll Lock"
        case .pause: return "Pause"
        }
    }
}

/// Action-mapped shortcut table (`rune::Keybind<A>`).
public struct Keybind<Action: Sendable>: Sendable {
    public var bindings: [(Chord, Action)] = []
    private var defaultChords: [Chord] = []
    private var platformOverrides: [(KeyPlatform, [Chord])] = []

    public init(_ specs: [(String, Action)] = []) {
        for (spec, action) in specs {
            if let chord = Chord(parsing: spec) {
                bindings.append((chord, action))
            }
        }
    }

    public mutating func bind(_ spec: String, to action: Action) {
        if let chord = Chord(parsing: spec) {
            bindings.append((chord, action))
        }
    }

    public func match(_ ev: KeyEvent) -> Action? {
        for (chord, action) in bindings.reversed() {
            if chord.matches(ev) {
                return action
            }
        }
        return nil
    }
}

extension Keybind where Action == Void {
    /// Creates a platform-aware multi-chord `Keybind` from a comma-separated spec (`chord.rs:277`).
    public static func new(_ spec: String) -> Keybind<Void> {
        do {
            var kb = Keybind<Void>()
            kb.defaultChords = try Chord.parseList(spec)
            return kb
        } catch {
            fatalError("Invalid keybind spec '\(spec)': \(error)")
        }
    }

    /// Overrides the chords used on `platform` (`chord.rs:283`).
    public func on(_ platform: KeyPlatform, _ spec: String) -> Keybind<Void> {
        do {
            let parsed = try Chord.parseList(spec, platform: platform)
            return onChords(platform, parsed)
        } catch {
            fatalError("Invalid keybind spec '\(spec)' on \(platform): \(error)")
        }
    }

    /// Overrides the chords used on `platform` (`chord.rs:288`).
    public func onChords(_ platform: KeyPlatform, _ chords: [Chord]) -> Keybind<Void> {
        var copy = self
        copy.platformOverrides.removeAll { $0.0 == platform }
        copy.platformOverrides.append((platform, chords))
        return copy
    }

    /// Chords that apply on `platform` (`chord.rs:295`).
    public func chords(on platform: KeyPlatform = .current) -> [Chord] {
        platformOverrides.first(where: { $0.0 == platform })?.1 ?? defaultChords
    }

    /// Whether `ev` matches any of `platform`'s chords (`chord.rs:309`).
    public func matches(_ ev: KeyEvent, on platform: KeyPlatform = .current) -> Bool {
        chords(on: platform).contains { $0.matches(ev, on: platform) }
    }

    /// First chord's label on `platform`, or `""` when nothing is bound (`chord.rs:322`).
    public func label(on platform: KeyPlatform = .current) -> String {
        chords(on: platform).first?.label(on: platform) ?? ""
    }

    /// Canonical comma-separated spec on `platform` (`"none"` when empty, `chord.rs:327`).
    public func spec(on platform: KeyPlatform = .current) -> String {
        let active = chords(on: platform)
        guard !active.isEmpty else { return "none" }
        return active.map(\.canonicalString).joined(separator: ", ")
    }
}

/// Rich clipboard payload (`rune::ClipboardContent`): plain text and optionally HTML, RTF, an
/// image and files. Its description shows only sizes, never the contents.
public struct ClipboardContent: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var text: String
    public var html: String?
    public var rtf: String?
    public var image: ClipboardImage?
    /// Files on the clipboard. Like the image, only pastes to a hook carry them (`ClipboardContent::files`).
    public var files: [URL]
    /// The clipboard still holds the pill copy this runtime wrote last (`own_pills`). Not part of equality.
    internal var ownPills: Bool = false

    public init(_ text: String = "", html: String? = nil, rtf: String? = nil, image: ClipboardImage? = nil, files: [URL] = []) {
        self.text = text
        self.html = html
        self.rtf = rtf
        self.image = image
        self.files = files
    }

    public static func == (a: ClipboardContent, b: ClipboardContent) -> Bool {
        a.text == b.text && a.html == b.html && a.rtf == b.rtf && a.image == b.image && a.files == b.files
    }

    public var description: String {
        "ClipboardContent(text: \(text.utf8.count), html: \(html.map { String($0.utf8.count) } ?? "nil"), "
            + "rtf: \(rtf.map { String($0.utf8.count) } ?? "nil"), image: \(image.map { "\($0.width)x\($0.height)" } ?? "nil"), files: \(files.count))"
    }

    public var debugDescription: String { description }
}

/// Colored inline mark over a UTF-8 byte range inside `TextEdit`.
public struct TextMark: Sendable, Equatable {
    public var utf8Range: Range<Int>
    public var textColor: Color?
    public var background: Color?

    public init(utf8Range: Range<Int>, textColor: Color? = nil, background: Color? = nil) {
        self.utf8Range = utf8Range
        self.textColor = textColor
        self.background = background
    }
}

/// Grapheme-cluster-safe single-line and multiline text editor state (`rune::TextEdit`).
///
/// Caret and selection anchor are stored as UTF-8 byte offsets snapped strictly to extended
/// grapheme cluster (`Character`) boundaries, so ZWJ emoji, flags, and combining accents never split.
public struct TextEdit: Sendable, Equatable {
    /// Coalescing behavior of an edit within the open typing run (`crates/rune/src/edit/history.rs`).
    public enum EditKind: Sendable, Equatable {
        case text
        case lineBreak
        case delete
        case deleteRun
        case other
    }

    private enum HistoryRun: Equatable {
        case closed
        case inserting
        case deleting
    }

    private enum HistoryRecord: Equatable {
        case join
        case push
    }

    private enum UndoGroupState {
        case closed
        case open(Snapshot)
        case unrecorded

        var isOpen: Bool {
            if case .closed = self { return false }
            return true
        }
    }

    internal struct Snapshot: Sendable, Equatable {
        var text: String
        var cursor: Int
        var anchor: Int
        var marks: [TextMark]
        var richMarks: [RichMarkRange]
        var blocks: [Block]
        var softBreaks: [Int]
    }

    public static let maxHistorySteps = 128
    public static let maxHistoryBytes = 1024 * 1024
    public static let multilineSecureMask = "••••••••••••"

    public private(set) var text: String
    /// Active caret position in UTF-8 bytes (`0...text.utf8.count`).
    public private(set) var cursor: Int
    /// Selection anchor in UTF-8 bytes (`anchor == cursor` when collapsed).
    public private(set) var anchor: Int
    public var multiline: Bool
    public var isSecure: Bool = false {
        didSet {
            if isSecure && !oldValue {
                undoStack.removeAll()
                redoStack.removeAll()
                historyBytes = 0
                historyRun = .closed
                if undoGroupState.isOpen {
                    undoGroupState = .unrecorded
                }
                marks.removeAll()
                richMarks.removeAll()
                blocks.removeAll()
                softBreaks.removeAll()
                typingStyle = .inherited
                preedit = nil
                preeditClauses.removeAll()
            } else if !isSecure && oldValue {
                if case .unrecorded = undoGroupState {
                    syncRichInvariants()
                    undoGroupState = .open(makeSnapshot())
                }
            }
        }
    }
    public var isRevealed: Bool = false
    public var spellcheckEnabled: Bool = false
    public var marks: [TextMark] = []
    public internal(set) var richMarks: [RichMarkRange] = []
    public internal(set) var blocks: [Block] = [.paragraph]
    public internal(set) var softBreaks: [Int] = []
    public var allowedRichMarks: RichMark.AllowMask? = nil {
        didSet { syncRichInvariants() }
    }
    public var allowedBlocks: Block.AllowMask? = nil {
        didSet { syncRichInvariants() }
    }
    public var isRichEnabled: Bool = false
    internal var typingStyle: TypingStyle = .inherited
    public internal(set) var caretColumn: CaretColumn = .free
    public internal(set) var caretAffinity: TextAffinity = .downstream
    /// Optional Ctrl+Shift forced paragraph direction (`direction_keys.rs`).
    public var dir: FieldDir = .natural
    /// Optional open IME composition `(preeditText, cursorRangeInBytes)`.
    public var preedit: (text: String, cursor: Range<Int>?)? = nil {
        didSet {
            if preedit == nil && !preeditClauses.isEmpty {
                preeditClauses.removeAll()
            }
        }
    }
    /// Platform-supplied IME clauses for the open preedit composition (`rune::edit::Clause`).
    public var preeditClauses: [ImeClause] = []
    /// Set when the last key press in `handleKey` requested blurring focus (e.g. non-composing Escape).
    public private(set) var didRequestBlur: Bool = false
    private var editedTag: Bool = false

    /// Whether `text` is non-empty and still holds the value last set via `init` or `replaceText` (`TextEdit::is_pristine`).
    public var isPristine: Bool { !text.isEmpty && !editedTag }

    /// Marks the current `text` as user-edited (`!isPristine`, `TextEdit::mark_edited`).
    public mutating func markEdited() { editedTag = true }

    /// True when this is a masked multi-line secure field (`isSecure && multiline && !isRevealed`).
    public var isHiddenMultiline: Bool { isSecure && multiline && !isRevealed }

    private var undoStack: [HistoryChange] = []
    private var redoStack: [HistoryChange] = []
    private var historyBytes: Int = 0
    private var historyRun: HistoryRun = .closed
    private var undoGroupState: UndoGroupState = .closed

    public static func == (lhs: TextEdit, rhs: TextEdit) -> Bool {
        lhs.text == rhs.text &&
        lhs.cursor == rhs.cursor &&
        lhs.anchor == rhs.anchor &&
        lhs.multiline == rhs.multiline &&
        lhs.isSecure == rhs.isSecure &&
        lhs.isRevealed == rhs.isRevealed &&
        lhs.marks == rhs.marks &&
        lhs.richMarks == rhs.richMarks &&
        lhs.blocks == rhs.blocks &&
        lhs.softBreaks == rhs.softBreaks &&
        lhs.dir == rhs.dir &&
        lhs.preedit?.text == rhs.preedit?.text &&
        lhs.preedit?.cursor == rhs.preedit?.cursor &&
        lhs.preeditClauses == rhs.preeditClauses
    }

    public init(_ initial: String = "", multiline: Bool = false) {
        let cleaned = multiline ? initial : initial.replacingOccurrences(of: "\n", with: " ")
        self.text = cleaned
        let end = cleaned.utf8.count
        self.cursor = end
        self.anchor = end
        self.multiline = multiline
        let lineCount = 1 + cleaned.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        self.blocks = Array(repeating: .paragraph, count: lineCount)
    }

    public var hasSelection: Bool { cursor != anchor }

    public var selectedUTF8Range: Range<Int> {
        min(cursor, anchor)..<max(cursor, anchor)
    }

    public var selectedText: String {
        guard hasSelection else { return "" }
        let r = selectedUTF8Range
        let s = stringIndex(forUTF8Offset: r.lowerBound)
        let e = stringIndex(forUTF8Offset: r.upperBound)
        return String(text[s..<e])
    }

    /// Replaces the entire text and places the caret at the end.
    public mutating func setText(_ newText: String, recordUndo: Bool = false) {
        let before = recordUndo ? captureUndoBaseline() : nil
        let cleaned = multiline ? newText : newText.replacingOccurrences(of: "\n", with: " ")
        text = cleaned
        let end = cleaned.utf8.count
        cursor = end
        anchor = end
        marks.removeAll()
        richMarks.removeAll()
        let lineCount = isSecure ? 0 : 1 + cleaned.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        blocks = Array(repeating: .paragraph, count: lineCount)
        softBreaks.removeAll()
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
        preedit = nil
        if recordUndo {
            recordUndoChange(before: before, kind: .other)
        }
    }

    /// Replaces the entire draft and discards undo/redo history while re-arming `isPristine` and preserving secure mode (`edit.rs:470`, `TextEdit::replace_text`).
    public mutating func replaceText(_ newText: String) {
        setText(newText, recordUndo: false)
        clearHistory()
        editedTag = false
    }

    public mutating func clear() {
        setText("", recordUndo: false)
        clearHistory()
    }

    public mutating func selectAll() {
        breakHistoryGroup()
        anchor = 0
        cursor = text.utf8.count
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
    }

    public mutating func collapseSelectionToStart() {
        breakHistoryGroup()
        let pos = min(cursor, anchor)
        cursor = pos
        anchor = pos
        snapToPills()
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
    }

    public mutating func collapseSelectionToEnd() {
        breakHistoryGroup()
        let pos = max(cursor, anchor)
        cursor = pos
        anchor = pos
        snapToPills()
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
    }

    public mutating func setCursor(utf8Offset: Int, extendSelection: Bool = false) {
        breakHistoryGroup()
        let snapped = snapToGraphemeBoundary(utf8Offset)
        cursor = snapped
        if !extendSelection {
            anchor = snapped
        }
        snapToPills()
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
    }

    public mutating func selectWord(atUTF8Offset offset: Int) {
        breakHistoryGroup()
        let snapped = snapToGraphemeBoundary(offset)
        let left = prevWordBoundary(from: snapped == text.utf8.count ? snapped : nextGraphemeBoundary(from: snapped))
        let right = nextWordBoundary(from: left)
        anchor = left
        cursor = right
        snapToPills()
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
    }

    /// Selects the hard `\n`-delimited paragraph containing `offset`, including its trailing newline
    /// when not the final line (`input_click_tests.rs:164`).
    public mutating func selectHardLine(atUTF8Offset offset: Int) {
        breakHistoryGroup()
        let r = hardLineParagraphRange(atUTF8Offset: offset)
        anchor = r.0
        cursor = r.1
        snapToPills()
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
    }

    internal func wordUnitRange(atUTF8Offset offset: Int) -> (Int, Int) {
        let snapped = snapToGraphemeBoundary(offset)
        let left = prevWordBoundary(from: snapped == text.utf8.count ? snapped : nextGraphemeBoundary(from: snapped))
        let right = nextWordBoundary(from: left)
        return (left, right)
    }

    internal func hardLineParagraphRange(atUTF8Offset offset: Int) -> (Int, Int) {
        let lineIdx = lineIndexOfUTF8(offset)
        let lineRange = lineRangeUTF8(of: lineIdx)
        let textCount = text.utf8.count
        let end = (lineRange.upperBound < textCount) ? lineRange.upperBound + 1 : lineRange.upperBound
        return (lineRange.lowerBound, end)
    }

    /// Inserts `inserted` at the current caret or replaces any active selection.
    public mutating func insert(_ inserted: String) {
        insert(inserted, kind: .other)
    }

    internal mutating func insert(_ inserted: String, kind: EditKind) {
        let filtered = sanitizeInput(inserted)
        let rawRange = (isHiddenMultiline && isPristine)
            ? (0..<text.utf8.count)
            : selectedUTF8Range
        let covered = coverPills(rawRange.lowerBound, rawRange.upperBound)
        let range = covered.0..<covered.1
        guard !filtered.isEmpty || !range.isEmpty else { return }
        let insertedMarks: [RichMark] = typingStyle.takeAt(anchor: anchor, cursor: cursor)
            ?? inheritedRichMarks(at: range.lowerBound)
        let before = captureUndoBaseline()
        let newLen = filtered.utf8.count
        applyRichReplace(range: range, replacement: filtered, insertedMarks: insertedMarks, newLineBlock: nil, markNewLinesSoft: false)
        adjustMarks(replacedRange: range, newLength: newLen)
        let newCursor = range.lowerBound + newLen
        cursor = newCursor
        anchor = newCursor
        caretColumn = .free
        caretAffinity = .downstream
        preedit = nil
        recordUndoChange(before: before, kind: kind)
        markEdited()
    }

    /// Deletes backward (or the active selection, or previous word when `word == true`).
    /// For un-selected clusters, deletes one scalar (so accents/Vowel signs peel cleanly) unless CR LF or emoji sequence.
    public mutating func backspace(word: Bool = false) {
        backspace(word: word, line: false, kind: .other)
    }

    internal mutating func backspace(word: Bool, line: Bool, kind: EditKind) {
        if hasSelection || (isHiddenMultiline && isPristine) {
            insert("", kind: kind)
            return
        }
        if !line && !word && !isSecure {
            syncRichInvariants()
            let lineIdx = lineIndexOfUTF8(cursor)
            let lineRange = lineRangeUTF8(of: lineIdx)
            let blk = lineIdx < blocks.count ? blocks[lineIdx] : .paragraph
            let isSoft = softBreaks.contains(lineIdx)
            if cursor == lineRange.lowerBound && !isSoft && blk != .paragraph {
                switch blk {
                case .bullet(let lvl):
                    setBlock(lvl > 0 ? .bullet(lvl - 1) : .paragraph)
                    return
                case .numbered(let lvl):
                    setBlock(lvl > 0 ? .numbered(lvl - 1) : .paragraph)
                    return
                case .quote, .code:
                    if cursor == 0 || lineRange.isEmpty {
                        setBlock(.paragraph)
                        return
                    }
                case .paragraph:
                    break
                }
            }
        }
        guard cursor > 0 else { return }
        let target: Int
        if line {
            target = (isSecure && !isRevealed) ? 0 : lineStart(for: cursor)
        } else if let pillStart = pillBefore(cursor) {
            target = pillStart
        } else {
            target = word ? prevWordBoundary(from: cursor) : prevBackspaceBoundary(from: cursor)
        }
        let covered = coverPills(target, cursor)
        let range = covered.0..<covered.1
        let before = captureUndoBaseline()
        applyRichReplace(range: range, replacement: "", insertedMarks: [], newLineBlock: nil, markNewLinesSoft: false)
        adjustMarks(replacedRange: range, newLength: 0)
        cursor = snapToGraphemeBoundary(range.lowerBound)
        anchor = cursor
        caretColumn = .free
        caretAffinity = .downstream
        recordUndoChange(before: before, kind: kind)
        markEdited()
    }

    /// Deletes one extended grapheme cluster forward (or the active selection, or next word when `word == true`).
    public mutating func deleteForward(word: Bool = false) {
        deleteForward(word: word, kind: .other)
    }

    internal mutating func deleteForward(word: Bool, kind: EditKind) {
        if hasSelection || (isHiddenMultiline && isPristine) {
            insert("", kind: kind)
            return
        }
        guard cursor < text.utf8.count else { return }
        let target: Int
        if let pillEnd = pillAfter(cursor) {
            target = pillEnd
        } else {
            target = word ? nextWordBoundary(from: cursor) : nextGraphemeBoundary(from: cursor)
        }
        let covered = coverPills(cursor, target)
        let range = covered.0..<covered.1
        let before = captureUndoBaseline()
        applyRichReplace(range: range, replacement: "", insertedMarks: [], newLineBlock: nil, markNewLinesSoft: false)
        adjustMarks(replacedRange: range, newLength: 0)
        cursor = snapToGraphemeBoundary(range.lowerBound)
        anchor = cursor
        caretColumn = .free
        caretAffinity = .downstream
        recordUndoChange(before: before, kind: kind)
        markEdited()
    }

    public mutating func moveLeft(extend: Bool = false, word: Bool = false, toLineBoundary: Bool = false) {
        if !extend && hasSelection && !word && !toLineBoundary {
            collapseSelectionToStart()
            return
        }
        let nextPos: Int
        if toLineBoundary {
            nextPos = lineStart(for: cursor)
        } else if word {
            nextPos = prevWordBoundary(from: cursor)
        } else if let pillStart = pillBefore(cursor) {
            nextPos = pillStart
        } else {
            nextPos = prevGraphemeBoundary(from: cursor)
        }
        setCursor(utf8Offset: nextPos, extendSelection: extend)
    }

    public mutating func moveRight(extend: Bool = false, word: Bool = false, toLineBoundary: Bool = false) {
        if !extend && hasSelection && !word && !toLineBoundary {
            collapseSelectionToEnd()
            return
        }
        let nextPos: Int
        if toLineBoundary {
            nextPos = lineEnd(for: cursor)
        } else if word {
            nextPos = nextWordBoundary(from: cursor)
        } else if let pillEnd = pillAfter(cursor) {
            nextPos = pillEnd
        } else {
            nextPos = nextGraphemeBoundary(from: cursor)
        }
        setCursor(utf8Offset: nextPos, extendSelection: extend)
    }

    private mutating func moveVerticalKey(down: Bool, extend: Bool, layout: ShapedText?, textSystem: TextSystem?, pixelScale: Float) {
        if let layout {
            moveLine(delta: down ? 1 : -1, in: layout, textSystem: textSystem ?? TextSystem(), pixelScale: pixelScale, extend: extend)
        } else if down {
            moveDown(extend: extend)
        } else {
            moveUp(extend: extend)
        }
    }

    public mutating func moveUp(extend: Bool = false) {
        guard multiline else {
            setCursor(utf8Offset: 0, extendSelection: extend)
            return
        }
        let curLineStart = lineStart(for: cursor)
        guard curLineStart > 0 else {
            setCursor(utf8Offset: 0, extendSelection: extend)
            return
        }
        let colChars = graphemeCount(from: curLineStart, to: cursor)
        let prevLineEnd = curLineStart - 1
        let prevLineStart = lineStart(for: prevLineEnd)
        let target = utf8Offset(from: prevLineStart, advancingGraphemes: colChars, limit: prevLineEnd)
        setCursor(utf8Offset: target, extendSelection: extend)
    }

    public mutating func moveDown(extend: Bool = false) {
        guard multiline else {
            setCursor(utf8Offset: text.utf8.count, extendSelection: extend)
            return
        }
        let curLineStart = lineStart(for: cursor)
        let curLineEnd = lineEnd(for: cursor)
        guard curLineEnd < text.utf8.count else {
            setCursor(utf8Offset: text.utf8.count, extendSelection: extend)
            return
        }
        let colChars = graphemeCount(from: curLineStart, to: cursor)
        let nextLineStart = curLineEnd + 1
        let nextLineEnd = lineEnd(for: nextLineStart)
        let target = utf8Offset(from: nextLineStart, advancingGraphemes: colChars, limit: nextLineEnd)
        setCursor(utf8Offset: target, extendSelection: extend)
    }

    public func copy() -> String? {
        guard !isSecure && hasSelection else { return nil }
        return selectedText
    }

    public mutating func cut() -> String? {
        guard !isSecure && hasSelection else { return nil }
        let out = selectedText
        insert("")
        return out
    }

    public mutating func paste(_ pasted: String) {
        insert(pasted)
    }

    /// Replaces any revealed secret with bullet masks and hides the field again (`TextEdit::conceal`).
    public mutating func conceal() {
        isRevealed = false
        guard isSecure else { return }
        text = displayString
        let end = text.utf8.count
        cursor = end
        anchor = end
        marks.removeAll()
        richMarks.removeAll()
        blocks.removeAll()
        softBreaks.removeAll()
        typingStyle = .inherited
        preedit = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private var isRecordingHistory: Bool {
        !isSecure && !undoGroupState.isOpen
    }

    /// Drops the undo and redo stacks while keeping the document and selection (`history.rs:153`).
    public mutating func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        historyBytes = 0
        historyRun = .closed
        if undoGroupState.isOpen {
            syncRichInvariants()
            undoGroupState = isSecure ? .unrecorded : .open(makeSnapshot())
        }
    }

    /// Ends the current typing coalescing run (on pointer selection, focus change, or non-typing command).
    public mutating func breakHistoryGroup() {
        historyRun = .closed
    }

    /// Runs `body`, coalescing all document mutations inside it into one undo step (`history.rs:259`).
    public mutating func undoGroup<R>(_ body: (inout TextEdit) -> R) -> R {
        if undoGroupState.isOpen {
            return body(&self)
        }
        syncRichInvariants()
        breakHistoryGroup()
        undoGroupState = isSecure ? .unrecorded : .open(makeSnapshot())
        let result = body(&self)
        let baseline: Snapshot?
        switch undoGroupState {
        case .open(let snap): baseline = snap
        case .closed, .unrecorded: baseline = nil
        }
        undoGroupState = .closed
        syncRichInvariants()
        breakHistoryGroup()
        recordUndoChange(before: baseline, kind: .other)
        return result
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard isRecordingHistory else { return false }
        breakHistoryGroup()
        if preedit != nil {
            cancelPreedit()
            return true
        }
        guard let change = undoStack.popLast() else { return false }
        historyBytes = max(0, historyBytes - change.byteCost)
        // Public model text may have been replaced by the app. Never restore stale history.
        if !change.leadsTo(text, after: true) {
            undoStack.removeAll()
            redoStack.removeAll()
            historyBytes = 0
            return false
        }
        restoreChange((change.at, change.inserted.utf8.count, change.removed), change.before)
        redoStack.append(change)
        historyBytes += change.byteCost
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard isRecordingHistory else { return false }
        breakHistoryGroup()
        if preedit != nil {
            cancelPreedit()
            return true
        }
        guard let change = redoStack.popLast() else { return false }
        historyBytes = max(0, historyBytes - change.byteCost)
        if !change.leadsTo(text, after: false) {
            undoStack.removeAll()
            redoStack.removeAll()
            historyBytes = 0
            return false
        }
        restoreChange((change.at, change.removed.utf8.count, change.inserted), change.after)
        undoStack.append(change)
        historyBytes += change.byteCost
        return true
    }

    /// Text bytes `at..<at + len` become `with`, and the rest of the document `meta` (`history::restore`).
    private mutating func restoreChange(_ edit: (at: Int, len: Int, with: String), _ meta: HistoryMeta) {
        HistoryText.replace(&text, edit.at, edit.len, with: edit.with)
        cursor = meta.cursor
        anchor = meta.anchor
        marks = meta.marks
        richMarks = meta.richMarks
        blocks = meta.blocks
        softBreaks = meta.softBreaks
        typingStyle = .inherited
        caretColumn = .free
        caretAffinity = .downstream
        preedit = nil
        preeditClauses.removeAll()
        syncRichInvariants()
    }

    internal func makeSnapshot() -> Snapshot {
        Snapshot(
            text: text,
            cursor: cursor,
            anchor: anchor,
            marks: marks,
            richMarks: richMarks,
            blocks: blocks,
            softBreaks: softBreaks
        )
    }

    internal func captureUndoBaseline() -> Snapshot? {
        isRecordingHistory ? makeSnapshot() : nil
    }

    private static func stepHistory(
        run: inout HistoryRun,
        kind: EditKind,
        intoEmpty: Bool
    ) -> HistoryRecord {
        let record: HistoryRecord
        let next: HistoryRun
        switch (run, kind) {
        case (_, .other):
            (record, next) = (.push, .closed)
        case (_, .deleteRun), (.closed, .delete), (.inserting, .delete):
            (record, next) = (.push, .deleting)
        case (.deleting, .delete):
            (record, next) = (.join, .deleting)
        case (.closed, .text), (.closed, .lineBreak):
            (record, next) = (.push, .inserting)
        case (.inserting, .text), (.inserting, .lineBreak), (.deleting, .text), (.deleting, .lineBreak):
            (record, next) = (.join, .inserting)
        }
        run = (kind == .text && intoEmpty) ? .closed : next
        return record
    }

    internal mutating func recordUndoChange(before: Snapshot?, kind: EditKind = .other) {
        guard let before, isRecordingHistory else { return }
        // What the edit left, read in place: copying a long document to compare it costs more
        // than the edit.
        let after = HistoryMeta(anchor: anchor, cursor: cursor, marks: marks, richMarks: richMarks, blocks: blocks, softBreaks: softBreaks)
        // Bytes, as upstream compares (`before.text.as_str() == self.text`): Swift's `==` takes
        // canonically equivalent texts (NFC é and NFD e + U+0301) as one.
        if HistoryText.sameBytes(before.text, text) && before.marks == after.marks && before.richMarks == after.richMarks
            && before.blocks == after.blocks && before.softBreaks == after.softBreaks {
            return
        }
        let change = HistoryChange.toText(before, text, after: after)

        // Public model text may have been replaced by the app: a history that doesn't lead to
        // the document this edit started from is dropped.
        let leads: Bool
        if let c = redoStack.last {
            leads = c.leadsTo(before.text, after: false)
        } else if let c = undoStack.last {
            leads = c.leadsTo(before.text, after: true)
        } else {
            leads = true
        }
        if !leads {
            undoStack.removeAll()
            redoStack.removeAll()
            historyBytes = 0
            historyRun = .closed
        }

        if !redoStack.isEmpty {
            let redoCost = redoStack.reduce(0) { $0 + $1.byteCost }
            historyBytes = max(0, historyBytes - redoCost)
            redoStack.removeAll()
        }

        let rec = Self.stepHistory(
            run: &historyRun,
            kind: kind,
            intoEmpty: isRichEnabled && before.text.isEmpty
        )
        if rec == .join,
           before.anchor == before.cursor,
           let last = undoStack.last,
           last.after == change.before,
           last.leadsTo(before.text, after: true) {
            let idx = undoStack.count - 1
            historyBytes = max(0, historyBytes - last.byteCost)
            undoStack[idx].join(mid: before.text, next: change)
            historyBytes += undoStack[idx].byteCost
        } else {
            historyBytes += change.byteCost
            undoStack.append(change)
        }

        // The newest step stays, however large: it's the way back from what was just done.
        while undoStack.count > 1 && (undoStack.count > Self.maxHistorySteps || historyBytes > Self.maxHistoryBytes) {
            let dropped = undoStack.removeFirst()
            historyBytes = max(0, historyBytes - dropped.byteCost)
        }
    }

    internal mutating func pushUndoSnapshot(_ before: Snapshot, kind: EditKind = .other) {
        recordUndoChange(before: before, kind: kind)
    }

    // MARK: - Persistent Undo/Redo JSON History (crates/rune/src/edit/history.rs, #880, #990)

    /// What a stored history looks like (`TextEdit::history_json`): version 2, each step a change;
    /// version 1 stored the document before and after each step, and still reads (`#990`).
    internal static let historyFormatVersion = 2

    /// Number of recorded undo and redo steps (`edit.history_len()`, `#880`).
    public func historyLen() -> (undo: Int, redo: Int) {
        (undoStack.count, redoStack.count)
    }

    /// The undo and redo history as JSON, for an app to keep past a restart and give back with
    /// `restoreHistoryJson`: the document's text as it is, and the newest steps, at most `maxSteps`
    /// of them and about `maxBytes` of changes between them (each step the text it replaced and the
    /// selection, marks and blocks either side). The newest undo step is always there, however
    /// large. `nil` for a secure field, which records nothing, and for an empty history.
    public func historyJson(maxSteps: Int, maxBytes: Int) -> Data? {
        guard !isSecure, (!undoStack.isEmpty || !redoStack.isEmpty) else {
            return nil
        }
        var steps = 0
        var bytes = 0
        func fits(_ c: HistoryChange) -> Bool {
            steps += 1
            bytes += c.byteCost
            return steps <= maxSteps && bytes <= maxBytes
        }
        // The newest undo step first: it's the way back from what was done last.
        let newest: [String: Any]? = undoStack.last.map { c in _ = fits(c); return Self.historyChangeJSON(c) }
        var redoReversed: [Any] = []
        for c in redoStack.reversed() {
            guard fits(c) else { break }
            redoReversed.append(Self.historyChangeJSON(c))
        }
        var undoReversed: [Any] = []
        for c in undoStack.dropLast().reversed() {
            guard fits(c) else { break }
            undoReversed.append(Self.historyChangeJSON(c))
        }
        var undo: [Any] = Array(undoReversed.reversed())
        if let newest { undo.append(newest) }
        let payload: [String: Any] = [
            "v": Self.historyFormatVersion,
            "d": text,
            "undo": undo,
            "redo": Array(redoReversed.reversed()),
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// String convenience for `historyJson(maxSteps:maxBytes:)`.
    public func historyJsonString(maxSteps: Int, maxBytes: Int) -> String? {
        guard let data = historyJson(maxSteps: maxSteps, maxBytes: maxBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Takes back a history `historyJson` wrote, when it leads to this document. A history stored
    /// a few keystrokes before the document was (an app stores it less often than the text) gets
    /// one more step, from the document it was stored with to this one, so the first undo goes back
    /// to where the stored history stood. Anything that doesn't fit (a step whose text or offsets
    /// aren't in its document) is left out and the field keeps no history. Reads version 1 too.
    /// Returns whether it was taken.
    @discardableResult
    public mutating func restoreHistoryJson(_ data: Data) -> Bool {
        guard !isSecure, !undoGroupState.isOpen else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return false
        }
        let read: (String, [HistoryChange], [HistoryChange])?
        switch Self.historyInt(dict["v"]) {
        case 2: read = Self.historyReadV2(dict)
        case 1: read = Self.historyReadV1(dict)
        default: read = nil
        }
        guard let (doc, readUndo, readRedo) = read else { return false }
        var undo = readUndo
        var redo = readRedo
        guard Self.historyChainHolds(doc, undo: undo, redo: redo) else { return false }

        syncRichInvariants()
        let now = makeSnapshot()
        func same(_ m: HistoryMeta) -> Bool {
            HistoryText.sameBytes(doc, now.text) && m.marks == now.marks && m.richMarks == now.richMarks
                && m.blocks == now.blocks && m.softBreaks == now.softBreaks
        }
        let leadsHere = (undo.last?.after ?? redo.last?.before).map(same) ?? false
        if !leadsHere {
            guard let last = undo.last?.after else { return false }
            if HistoryText.sameBytes(doc, now.text) {
                return false
            }
            redo.removeAll()
            let stored = Snapshot(text: doc, cursor: last.cursor, anchor: last.anchor, marks: last.marks, richMarks: last.richMarks, blocks: last.blocks, softBreaks: last.softBreaks)
            undo.append(HistoryChange.between(stored, now))
        }

        var totalBytes = undo.reduce(0) { $0 + $1.byteCost } + redo.reduce(0) { $0 + $1.byteCost }
        // The newest step stays, however large.
        while undo.count > 1 && (undo.count > Self.maxHistorySteps || totalBytes > Self.maxHistoryBytes) {
            let dropped = undo.removeFirst()
            totalBytes = max(0, totalBytes - dropped.byteCost)
        }

        undoStack = undo
        redoStack = redo
        historyBytes = totalBytes
        historyRun = .closed
        return true
    }

    /// String convenience for `restoreHistoryJson(_ data:)`.
    @discardableResult
    public mutating func restoreHistoryJson(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        return restoreHistoryJson(data)
    }

    // MARK: - IME Preedit

    public mutating func setPreedit(
        _ preeditText: String,
        cursor cursorRange: Range<Int>? = nil,
        clauses: [ImeClause] = []
    ) {
        guard !isSecure else {
            preedit = nil
            preeditClauses.removeAll()
            return
        }
        if preeditText.isEmpty {
            preedit = nil
            preeditClauses.removeAll()
        } else {
            let validUTF8 = Self.utf8ScalarBoundarySet(in: preeditText)
            let clampedCursor = cursorRange.map { r in
                let lo = min(max(0, r.lowerBound), preeditText.utf8.count)
                let hi = min(max(lo, r.upperBound), preeditText.utf8.count)
                return lo..<hi
            }
            let fits: (ImeClause) -> Bool = { c in
                c.utf8Range.lowerBound < c.utf8Range.upperBound &&
                c.utf8Range.upperBound <= preeditText.utf8.count &&
                validUTF8.contains(c.utf8Range.lowerBound) &&
                validUTF8.contains(c.utf8Range.upperBound)
            }
            preedit = (preeditText, clampedCursor)
            preeditClauses = clauses.allSatisfy(fits) ? clauses : []
        }
    }

    public mutating func commitPreedit(_ committed: String) {
        preedit = nil
        preeditClauses.removeAll()
        guard !isSecure else { return }
        insert(committed, kind: .other)
    }

    public mutating func cancelPreedit() {
        preedit = nil
        preeditClauses.removeAll()
    }

    /// Commits any open preedit text if present (`Event::Finish` in `edit/ime.rs`), returning whether committed.
    @discardableResult
    public mutating func finishPreedit() -> Bool {
        guard let active = preedit, !active.text.isEmpty else {
            preedit = nil
            preeditClauses.removeAll()
            return false
        }
        let committed = active.text
        commitPreedit(committed)
        return true
    }

    /// Returns effective IME clauses for the active preedit (`Composition::clauses` in `edit/ime.rs`).
    public func effectivePreeditClauses() -> [ImeClause] {
        guard let active = preedit, !active.text.isEmpty else { return [] }
        if !preeditClauses.isEmpty { return preeditClauses }
        let len = active.text.utf8.count
        if let c = active.cursor, c.lowerBound < c.upperBound, c.upperBound <= len {
            return [
                ImeClause(utf8Range: 0..<c.lowerBound, isTarget: false),
                ImeClause(utf8Range: c.lowerBound..<c.upperBound, isTarget: true),
                ImeClause(utf8Range: c.upperBound..<len, isTarget: false),
            ].filter { !$0.utf8Range.isEmpty }
        }
        return [ImeClause(utf8Range: 0..<len, isTarget: false)]
    }

    /// Publishes surrounding paragraph context (at most `maxContextBytes` per side) for IME reconversion.
    /// Always returns `nil` when `isSecure == true`.
    public func imeTextSnapshot(maxContextBytes: Int = 1024) -> ImeText? {
        guard !isSecure else { return nil }
        return ImeUTF16Bridge.imeTextSlice(
            text: text,
            selectionUTF8: selectedUTF8Range,
            maxContextBytes: maxContextBytes
        )
    }

    /// Applies an OS `ImeEvent` (`rune::edit::ime::step`).
    @discardableResult
    public mutating func applyIme(_ event: ImeEvent) -> EditOutcome {
        switch event {
        case let .preedit(str, cursorUTF8, clauses):
            setPreedit(str, cursor: cursorUTF8, clauses: clauses)
            return .navigation
        case let .commit(str):
            if isSecure {
                preedit = nil
                preeditClauses.removeAll()
                return .ignored
            }
            let prev = text
            commitPreedit(str)
            return text != prev ? .modified : .navigation
        case let .select(range):
            guard preedit == nil, !isSecure else { return .ignored }
            let start = snapToGraphemeBoundary(range.lowerBound)
            let end = snapToGraphemeBoundary(range.upperBound)
            anchor = start
            cursor = end
            return .navigation
        case .enabled, .disabled:
            return .ignored
        }
    }

    private static func utf8ScalarBoundarySet(in s: String) -> Set<Int> {
        var set = Set<Int>()
        var offset = 0
        set.insert(0)
        for scalar in s.unicodeScalars {
            offset += scalar.utf8.count
            set.insert(offset)
        }
        return set
    }

    public enum EditOutcome: Sendable, Equatable {
        case ignored
        case navigation
        case modified
        case submit
        case copy(String)
    }

    /// Returns the inline mark mapped from a formatting shortcut chord (`b`/`i`/`u`) if allowed (`input.rs:274`).
    public func formatChord(_ ev: KeyEvent) -> RichMark? {
        guard isRichEnabled && !isSecure else { return nil }
        guard ev.mods.primaryCommand && ev.mods.primaryAlone && !ev.mods.shift else { return nil }
        let mark: RichMark
        if ev.isCommand("b") {
            mark = .bold
        } else if ev.isCommand("i") {
            mark = .italic
        } else if ev.isCommand("u") {
            mark = .underline
        } else {
            return nil
        }
        return allowsRichMark(mark) ? mark : nil
    }

    private func atEndOfTrailingBlock() -> Bool {
        let n = text.utf8.count
        return !isSecure
            && multiline
            && preedit == nil
            && anchor == n
            && cursor == n
            && (blocks.last == .code || blocks.last == .quote)
    }

    private mutating func leaveTrailingBlock() {
        syncRichInvariants()
        breakHistoryGroup()
        let before = captureUndoBaseline()
        let n = text.utf8.count
        typingStyle = .inherited
        applyRichReplace(
            range: n..<n,
            replacement: "\n",
            insertedMarks: [],
            newLineBlock: .paragraph,
            markNewLinesSoft: false
        )
        let newCursor = n + 1
        cursor = newCursor
        anchor = newCursor
        caretColumn = .free
        caretAffinity = .downstream
        recordUndoChange(before: before, kind: .other)
    }

    private mutating func insertNewline(blockForNewLine: Block, soft: Bool) {
        guard !isSecure && multiline else { return }
        syncRichInvariants()
        let before = captureUndoBaseline()
        let covered = coverPills(selectedUTF8Range.lowerBound, selectedUTF8Range.upperBound)
        let range = covered.0..<covered.1
        let insertedMarks = typingStyle.takeAt(anchor: anchor, cursor: cursor)
            ?? inheritedRichMarks(at: range.lowerBound)
        applyRichReplace(
            range: range,
            replacement: "\n",
            insertedMarks: insertedMarks,
            newLineBlock: blockForNewLine,
            markNewLinesSoft: soft
        )
        adjustMarks(replacedRange: range, newLength: 1)
        let newCursor = range.lowerBound + 1
        cursor = newCursor
        anchor = newCursor
        caretColumn = .free
        caretAffinity = .downstream
        recordUndoChange(before: before, kind: .lineBreak)
    }

    /// Processes a keyboard `KeyEvent`, returning how the editor responded.
    public mutating func handleKey(_ ev: KeyEvent) -> EditOutcome {
        handleKey(ev, layout: nil)
    }

    /// Processes a keyboard event using the field's shaped lines for visual navigation.
    public mutating func handleKey(_ ev: KeyEvent, layout: ShapedText?) -> EditOutcome {
        handleKey(ev, layout: layout, textSystem: nil, pixelScale: 1)
    }

    internal mutating func handleKey(_ ev: KeyEvent, layout: ShapedText?, textSystem: TextSystem?, pixelScale: Float) -> EditOutcome {
        didRequestBlur = false
        let shift = ev.mods.shift
        let alt = ev.mods.alt

        if isHiddenMultiline {
            switch ev.key {
            case .arrowLeft, .arrowRight, .arrowUp, .arrowDown, .home, .end:
                cursor = text.utf8.count
                anchor = shift ? 0 : cursor
                return .navigation
            default:
                break
            }
        }

        if let ctrlLetter = ev.controlBinding {
            switch ctrlLetter {
            case "a", "e", "b", "f", "p", "n":
                if isHiddenMultiline {
                    cursor = text.utf8.count
                    anchor = shift ? 0 : cursor
                    return .navigation
                }
                switch ctrlLetter {
                case "a": moveLeft(extend: shift, toLineBoundary: true)
                case "e": moveRight(extend: shift, toLineBoundary: true)
                case "b": moveLeft(extend: shift)
                case "f": moveRight(extend: shift)
                default:
                    moveVerticalKey(down: ctrlLetter == "n", extend: shift, layout: layout, textSystem: textSystem, pixelScale: pixelScale)
                }
                return .navigation
            case "d":
                let before = text
                deleteForward(word: false, kind: .delete)
                return text != before ? .modified : .navigation
            case "h":
                let beforeText = text
                let beforeBlocks = blocks
                backspace(word: false, line: false, kind: .delete)
                return (text != beforeText || blocks != beforeBlocks) ? .modified : .navigation
            case "k":
                breakHistoryGroup()
                if isHiddenMultiline && isPristine {
                    insert("", kind: .deleteRun)
                    return .modified
                }
                let end = lineEnd(for: cursor)
                if cursor < end || hasSelection {
                    if !hasSelection { anchor = end }
                    insert("", kind: .deleteRun)
                    return .modified
                }
                return .ignored
            default:
                break
            }
        }

        if ev.mods.primaryCommand && ev.mods.primaryAlone {
            breakHistoryGroup()
            if ev.isCommand("a") {
                selectAll()
                return .navigation
            }
            if ev.isCommand("z") {
                if shift {
                    return redo() ? .modified : .ignored
                } else {
                    return undo() ? .modified : .ignored
                }
            }
            if ev.isCommand("y") {
                return redo() ? .modified : .ignored
            }
            if ev.isCommand("b") || ev.isCommand("i") || ev.isCommand("u") {
                if let mark = formatChord(ev) {
                    toggleMark(mark)
                    return .modified
                }
                return .ignored
            }
            if ev.isCommand("c") {
                if let copied = copy() { return .copy(copied) }
                return .ignored
            }
            if ev.isCommand("x") {
                if let cutStr = cut() { return .copy(cutStr) }
                return .ignored
            }
            switch ev.key {
            case .arrowLeft:
                moveLeft(extend: shift, toLineBoundary: true)
                return .navigation
            case .arrowRight:
                moveRight(extend: shift, toLineBoundary: true)
                return .navigation
            case .arrowUp:
                setCursor(utf8Offset: 0, extendSelection: shift)
                return .navigation
            case .arrowDown:
                setCursor(utf8Offset: text.utf8.count, extendSelection: shift)
                return .navigation
            case .backspace:
                let start = lineStart(for: cursor)
                if start < cursor || hasSelection {
                    backspace(word: false, line: true, kind: .deleteRun)
                    return .modified
                }
                return .ignored
            case .delete:
                let end = lineEnd(for: cursor)
                if cursor < end || hasSelection {
                    let before = captureUndoBaseline()
                    let r = hasSelection ? selectedUTF8Range : cursor..<end
                    let covered = coverPills(r.lowerBound, r.upperBound)
                    let range = covered.0..<covered.1
                    applyRichReplace(range: range, replacement: "", insertedMarks: [], newLineBlock: nil, markNewLinesSoft: false)
                    adjustMarks(replacedRange: range, newLength: 0)
                    cursor = snapToGraphemeBoundary(range.lowerBound)
                    anchor = cursor
                    recordUndoChange(before: before, kind: .deleteRun)
                    markEdited()
                    return .modified
                }
                return .ignored
            case .enter:
                if multiline && isSecure {
                    return .submit
                }
                return .ignored
            default:
                return .ignored
            }
        }

        // AltGr / extra modifiers alongside Cmd other than Shift leave primary commands untouched.
        if ev.mods.primaryCommand {
            return .ignored
        }

        switch ev.key {
        case .text, .space, .backspace, .delete, .enter:
            break
        default:
            breakHistoryGroup()
        }

        switch ev.key {
        case .backspace:
            let beforeText = text
            let beforeBlocks = blocks
            let isWord = alt || ev.mods.ctrl
            backspace(word: isWord, line: false, kind: isWord ? .deleteRun : .delete)
            return (text != beforeText || blocks != beforeBlocks) ? .modified : .navigation

        case .delete:
            let before = text
            let isWord = alt || ev.mods.ctrl
            deleteForward(word: isWord, kind: isWord ? .deleteRun : .delete)
            return text != before ? .modified : .navigation

        case .arrowLeft:
            let word = alt || ev.mods.ctrl
            if !(!shift && hasSelection && !word),
               let (nextPos, aff) = visualStep(layout: layout, right: false, word: word) {
                setCursor(utf8Offset: nextPos, extendSelection: shift)
                caretAffinity = aff
            } else {
                moveLeft(extend: shift, word: word)
            }
            return .navigation

        case .arrowRight:
            if !shift && !alt && !ev.mods.ctrl && atEndOfTrailingBlock() {
                leaveTrailingBlock()
                return .modified
            }
            let word = alt || ev.mods.ctrl
            if !(!shift && hasSelection && !word),
               let (nextPos, aff) = visualStep(layout: layout, right: true, word: word) {
                setCursor(utf8Offset: nextPos, extendSelection: shift)
                caretAffinity = aff
            } else {
                moveRight(extend: shift, word: word)
            }
            return .navigation

        case .arrowUp, .arrowDown:
            let down = ev.key == .arrowDown
            if down && !shift && !alt && !ev.mods.ctrl && atEndOfTrailingBlock() {
                leaveTrailingBlock()
                return .modified
            }
            moveVerticalKey(down: down, extend: shift, layout: layout, textSystem: textSystem, pixelScale: pixelScale)
            return .navigation

        case .home:
            moveLeft(extend: shift, toLineBoundary: true)
            return .navigation

        case .end:
            moveRight(extend: shift, toLineBoundary: true)
            return .navigation

        case .enter:
            if preedit != nil {
                return .ignored
            }
            if !multiline {
                return .submit
            }
            if isSecure {
                if ev.mods.ctrl || ev.mods.cmd {
                    return .submit
                }
                insert("\n", kind: .lineBreak)
                return .modified
            }
            syncRichInvariants()
            let r = selectedUTF8Range
            let lineIdx = lineIndexOfUTF8(r.lowerBound)
            let blk = lineIdx < blocks.count ? blocks[lineIdx] : .paragraph
            let lineRange = lineRangeUTF8(of: lineIdx)
            if shift && isRichEnabled {
                insertNewline(blockForNewLine: blk, soft: true)
                return .modified
            }
            if shift || alt {
                insertNewline(blockForNewLine: blk, soft: false)
                return .modified
            }
            switch blk {
            case .code:
                let nextNotCode = (lineIdx + 1 >= blocks.count) || blocks[lineIdx + 1] != .code
                if r.isEmpty && lineRange.isEmpty && nextNotCode {
                    setBlock(.paragraph)
                } else {
                    insertNewline(blockForNewLine: .code, soft: false)
                }
                return .modified
            case .bullet, .numbered, .quote:
                if r.isEmpty && lineRange.isEmpty {
                    setBlock(.paragraph)
                } else {
                    insertNewline(blockForNewLine: blk, soft: false)
                }
                return .modified
            case .paragraph:
                return .submit
            }

        case .tab:
            if !isSecure && multiline && !ev.mods.cmd && !alt && !ev.mods.ctrl {
                if activeBlock == .code && !shift {
                    insert("\t", kind: .text)
                    return .modified
                }
                if shift {
                    if outdentList() { return .modified }
                } else {
                    if indentList() { return .modified }
                }
            }
            return .ignored

        case .escape:
            if preedit != nil {
                cancelPreedit()
                return .modified
            }
            didRequestBlur = true
            return .ignored

        case .space:
            if !ev.mods.ctrl {
                insert(" ", kind: .text)
                return .modified
            }
            return .ignored

        case .text(let s):
            if !ev.mods.ctrl {
                let kind: EditKind = s.contains(where: { $0 == "\n" || $0 == "\r" }) ? .lineBreak : .text
                insert(s, kind: kind)
                return .modified
            }
            return .ignored

        default:
            return .ignored
        }
    }

    /// Masked display string (`"••••••••••••"` for hidden multi-line, `•` per scalar for hidden single-line).
    public var displayString: String {
        guard isSecure && !isRevealed else { return text }
        if multiline {
            return Self.multilineSecureMask
        }
        return String(repeating: "•", count: text.unicodeScalars.count)
    }

    // MARK: - Grapheme & Word Boundary Helpers

    public func snapToGraphemeBoundary(_ utf8Offset: Int) -> Int {
        let clamped = utf8Offset.clamped(to: 0...text.utf8.count)
        if clamped == 0 || clamped == text.utf8.count { return clamped }
        var bytePos = 0
        for ch in text {
            let nextPos = bytePos + ch.utf8.count
            if clamped <= nextPos {
                return (clamped - bytePos <= nextPos - clamped) ? bytePos : nextPos
            }
            bytePos = nextPos
        }
        return text.utf8.count
    }

    public func stringIndex(forUTF8Offset offset: Int) -> String.Index {
        let clamped = snapToGraphemeBoundary(offset)
        return text.utf8.index(text.utf8.startIndex, offsetBy: clamped)
    }

    private func prevGraphemeBoundary(from offset: Int) -> Int {
        let idx = stringIndex(forUTF8Offset: offset)
        guard idx > text.startIndex else { return 0 }
        let prev = text.index(before: idx)
        return text.utf8.distance(from: text.utf8.startIndex, to: prev.samePosition(in: text.utf8)!)
    }

    private func nextGraphemeBoundary(from offset: Int) -> Int {
        let idx = stringIndex(forUTF8Offset: offset)
        guard idx < text.endIndex else { return text.utf8.count }
        let next = text.index(after: idx)
        return text.utf8.distance(from: text.utf8.startIndex, to: next.samePosition(in: text.utf8)!)
    }

    private func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Text typed, pasted or committed into this field (`edit.rs::sanitize`). Single-line fields
    /// drop control characters, line breaks included (stripped, as `<input type=text>` does);
    /// multi-line fields fold CRLF to LF (and multi-line secure fields also drop control
    /// characters other than `\n` and `\t`, a lone CR becoming LF).
    private func sanitizeInput(_ s: String) -> String {
        let isControl: (Unicode.Scalar) -> Bool = { $0.properties.generalCategory == .control }
        let isLineSeparator: (Unicode.Scalar) -> Bool = { $0 == "\u{2028}" || $0 == "\u{2029}" }
        if !multiline {
            var out = String.UnicodeScalarView()
            for c in s.unicodeScalars where !isControl(c) && !isLineSeparator(c) { out.append(c) }
            return String(out)
        }
        if isSecure {
            var out = String.UnicodeScalarView()
            let scalars = Array(s.unicodeScalars)
            for (i, c) in scalars.enumerated() {
                if c == "\r" {
                    if i + 1 >= scalars.count || scalars[i + 1] != "\n" { out.append("\n") }
                    continue
                }
                if (!isControl(c) || c == "\n" || c == "\t") && !isLineSeparator(c) { out.append(c) }
            }
            return String(out)
        }
        // Most pastes: copied whole, not a character at a time (#990). Checked by byte:
        // `"\r\n"` is one `Character`, so `contains("\r")` would miss it.
        guard s.utf8.contains(0x0D) else { return s }
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        for (i, c) in scalars.enumerated() {
            if c == "\r" && i + 1 < scalars.count && scalars[i + 1] == "\n" { continue }
            out.append(c)
        }
        return String(out)
    }

    private func prevBackspaceBoundary(from offset: Int) -> Int {
        let start = prevGraphemeBoundary(from: offset)
        let lo = stringIndex(forUTF8Offset: start)
        let hi = stringIndex(forUTF8Offset: offset)
        let cluster = text[lo..<hi]
        if cluster == "\r\n" {
            return start
        }
        let isEmojiSeq = cluster.unicodeScalars.contains { scalar in
            let v = scalar.value
            return v == 0xFE0F
                || v == 0x20E3
                || (0x1F3FB...0x1F3FF).contains(v)
                || (0x1F1E6...0x1F1FF).contains(v)
                || (0xE0020...0xE007F).contains(v)
        } || (cluster.unicodeScalars.contains { $0.value == 0x200D } && cluster.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        })
        if isEmojiSeq {
            return start
        }
        guard offset > 0 else { return 0 }
        let scalarIdx = text.unicodeScalars.index(before: hi)
        return text.utf8.distance(from: text.utf8.startIndex, to: scalarIdx)
    }

    private func visualStep(layout: ShapedText?, right: Bool, word: Bool) -> (Int, TextAffinity)? {
        guard let shaped = layout else { return nil }
        let arrow: CaretArrow = {
            switch (right, word) {
            case (false, false): return .left
            case (true, false): return .right
            case (false, true): return .wordLeft
            case (true, true): return .wordRight
            }
        }()
        let hidden = isSecure && !isRevealed
        guard let (landing, flow) = CaretVisualStepper.visualIn(
            shaped,
            at: cursor,
            side: caretAffinity,
            arrow: arrow,
            hidden: hidden
        ) else {
            return nil
        }
        switch landing {
        case .at(let j, let side):
            return (snapToGraphemeBoundary(j), side)
        case .edge:
            let forward = right == (flow == .ltr)
            let nextPos: Int = {
                switch (forward, word) {
                case (true, false):
                    return pillAfter(cursor) ?? nextGraphemeBoundary(from: cursor)
                case (true, true):
                    return nextWordBoundary(from: cursor)
                case (false, false):
                    return pillBefore(cursor) ?? prevGraphemeBoundary(from: cursor)
                case (false, true):
                    return prevWordBoundary(from: cursor)
                }
            }()
            return (nextPos, .downstream)
        }
    }

    private func prevWordBoundary(from offset: Int) -> Int {
        prevWord(offset)
    }

    private func nextWordBoundary(from offset: Int) -> Int {
        nextWord(offset)
    }

    private func lineStart(for offset: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: offset)
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            if text[prev] == "\n" { break }
            idx = prev
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    private func lineEnd(for offset: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: offset)
        while idx < text.endIndex && text[idx] != "\n" {
            idx = text.index(after: idx)
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    private func graphemeCount(from startUTF8: Int, to endUTF8: Int) -> Int {
        guard endUTF8 > startUTF8 else { return 0 }
        let s = stringIndex(forUTF8Offset: startUTF8)
        let e = stringIndex(forUTF8Offset: endUTF8)
        return text.distance(from: s, to: e)
    }

    private func utf8Offset(from startUTF8: Int, advancingGraphemes count: Int, limit limitUTF8: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: startUTF8)
        let limitIdx = stringIndex(forUTF8Offset: limitUTF8)
        var remaining = count
        while remaining > 0 && idx < limitIdx {
            idx = text.index(after: idx)
            remaining -= 1
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    internal mutating func adjustMarks(replacedRange: Range<Int>, newLength: Int) {
        guard !marks.isEmpty else { return }
        let delta = newLength - replacedRange.count
        var updated: [TextMark] = []
        updated.reserveCapacity(marks.count)
        for var m in marks {
            if m.utf8Range.upperBound <= replacedRange.lowerBound {
                updated.append(m)
            } else if m.utf8Range.lowerBound >= replacedRange.upperBound {
                m.utf8Range = (m.utf8Range.lowerBound + delta)..<(m.utf8Range.upperBound + delta)
                updated.append(m)
            } else {
                let newLo = min(m.utf8Range.lowerBound, replacedRange.lowerBound)
                let tail = max(0, m.utf8Range.upperBound - replacedRange.upperBound)
                let newHi = newLo + max(0, min(m.utf8Range.upperBound, replacedRange.lowerBound) - newLo) + newLength + tail
                if newHi > newLo {
                    m.utf8Range = newLo..<newHi
                    updated.append(m)
                }
            }
        }
        marks = updated
    }

    internal mutating func setSelectionRaw(anchor newAnchor: Int, cursor newCursor: Int) {
        self.anchor = newAnchor
        self.cursor = newCursor
    }

    internal func lineRangeUTF8(of lineIndex: Int) -> Range<Int> {
        let start = lineStart(for: 0) // keep helper structure clear
        _ = start
        var cur = 0
        var lineLo = 0
        for (i, b) in text.utf8.enumerated() {
            if b == 0x0A {
                if cur == lineIndex { return lineLo..<i }
                lineLo = i + 1
                cur += 1
            }
        }
        if cur == lineIndex { return lineLo..<text.utf8.count }
        return text.utf8.count..<text.utf8.count
    }

    internal func lineIndexOfUTF8(_ byteOffset: Int) -> Int {
        let clamped = min(max(0, byteOffset), text.utf8.count)
        var count = 0
        var i = 0
        for b in text.utf8 {
            if i >= clamped { break }
            if b == 0x0A { count += 1 }
            i += 1
        }
        return count
    }
    internal mutating func setTextStorageRaw(_ newText: String) {
        self.text = newText
    }
}

// MARK: - Spellcheck Integration on TextEdit

extension TextEdit {
    /// Returns UTF-8 byte ranges of misspelled words when `spellcheckEnabled` is true and `!isSecure`.
    public func misspelledUTF8Ranges(using checker: SpellChecker = .shared) -> [Range<Int>] {
        guard spellcheckEnabled && !isSecure else { return [] }
        return checker.misspelledUTF8Ranges(in: text)
    }

    /// Returns `(range, word, suggestions)` if `offset` lies within a misspelled word.
    public func spellingSuggestions(
        atUTF8Offset offset: Int,
        using checker: SpellChecker = .shared
    ) -> (range: Range<Int>, word: String, suggestions: [String])? {
        let ranges = misspelledUTF8Ranges(using: checker)
        guard let hit = ranges.first(where: { $0.contains(offset) || $0.upperBound == offset }) else {
            return nil
        }
        let lo = stringIndex(forUTF8Offset: hit.lowerBound)
        let hi = stringIndex(forUTF8Offset: hit.upperBound)
        let word = String(text[lo..<hi])
        return (hit, word, checker.suggestions(for: word))
    }

    /// Replaces `range` (e.g. a misspelled word) with `replacement` while recording an undo snapshot.
    public mutating func replaceUTF8Range(_ range: Range<Int>, with replacement: String) {
        let lo = max(0, min(text.utf8.count, range.lowerBound))
        let hi = max(lo, min(text.utf8.count, range.upperBound))
        let before = captureUndoBaseline()
        let startIdx = stringIndex(forUTF8Offset: lo)
        let endIdx = stringIndex(forUTF8Offset: hi)
        text.replaceSubrange(startIdx..<endIdx, with: replacement)
        let newCursor = lo + replacement.utf8.count
        cursor = newCursor
        anchor = newCursor
        adjustMarks(replacedRange: lo..<hi, newLength: replacement.utf8.count)
        recordUndoChange(before: before, kind: .other)
    }
}

extension TextEdit: CustomDebugStringConvertible {
    public var debugDescription: String {
        let shownText = isSecure ? "[redacted]" : text
        return "TextEdit(text: \(String(reflecting: shownText)), anchor: \(anchor), cursor: \(cursor), marks: \(marks.count), blocks: \(blocks.count), isSecure: \(isSecure), isRevealed: \(isRevealed))"
    }
}
